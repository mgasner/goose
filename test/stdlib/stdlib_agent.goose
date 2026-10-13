// runtime-debug: stdlib/agent.goose, offline against the mock provider (mock/provider.goose):
// tool calls answered in one message, the registry's own refusals (unknown
// tool, input that is not an object or lacks a required property), a hook
// denying a call, every stop condition, resuming a stopped run, pause_turn,
// and the loop over an OpenAI-compatible provider.
import std;
import json;
import inference;
import agent;
import mock.provider;

let TOOLS: inference::Tool[] = [
    inference::Tool { name: "add", description: "Adds two integers.",
                      schema: "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]}" },
    inference::Tool { name: "broken", description: "Always fails." },
    inference::Tool { name: "danger", description: "Not allowed by the hook." },
];

fn tools(call: agent::Call, out: u8[>..]&) -> bool {
    if call.name == "add" {
        format(out, call.input.get("a").int() + call.input.get("b").int());
        return true;
    }
    if call.name == "broken" {
        out.append("the disk is full");
        return false;
    }
    out.append("ran");
    return true;
}

var stop_at_turn = 0;     // a turn whose request the hook stops; 0 for none

fn hook(e: agent::Event) -> bool {
    match e {
        Request r => {
            if r.turn == stop_at_turn { print("  hook: stop before request ", r.turn); return false; }
        },
        Reply r => print("  reply ", r.turn, ": ", r.res.stop_reason),
        Tool t => {
            if t.call.name == "danger" { print("  hook: deny ", t.call.id); return false; }
            print("  hook: allow ", t.call.id, " ", t.call.name, " ", t.call.text);
        },
        Result r => print("  ", r.call.id, if r.ok { " -> " } else { " -> error: " }, r.output),
    }
    return true;
}

fn show(r: agent::Run) {
    print("  run: stop=", agent::stop_name(r.stop), " turns=", r.turns, " calls=", r.tool_calls,
          " tokens=", r.input_tokens, "/", r.output_tokens,
          if r.res.error.len > 0 { str(" error=", r.res.error) } else { str("") });
}

// An Anthropic reply: content blocks, stop reason, output tokens.
fn msg(content: const u8[:], stop: const u8[:], out_tokens: i64 = 10) {
    reply(200, str("{\"id\":\"msg\",\"type\":\"message\",\"model\":\"claude-opus-5-5\",\"content\":[", content,
                   "],\"stop_reason\":\"", stop, "\",\"usage\":{\"input_tokens\":100,\"output_tokens\":",
                   out_tokens, "}}"));
}

fn use(id: const u8[:], name: const u8[:], input: const u8[:]) -> u8[>..] {
    str("{\"type\":\"tool_use\",\"id\":\"", id, "\",\"name\":\"", name, "\",\"input\":", input, "}")
}

fn text(t: const u8[:]) -> u8[>..] { str("{\"type\":\"text\",\"text\":\"", t, "\"}") }

// The messages of the request the mock got last, from the given one on.
fn seen_messages(from: i64) {
    let s = qget<Seen>();
    let d = json::parse(s.body);
    let ms = d.root().get("messages");
    for i in from..ms.count() {
        var out: u8[>..] = [];
        var w = json::writer(out);
        w.value(ms.at(i));
        print("  > ", out);
    }
}

fn skip_seen(n: i64) { for i in n { qget<Seen>(); } }

fn main() {
    let base = start_mock();
    var c = inference::anthropic("sk-test", base);
    let p = inference::Params { system: "Use the tools.", tools: TOOLS, .. };

    print("-- calls, one reply, answered in one message");
    var conv: inference::Item..[>..] = [];
    inference::user(conv, "Do things.");
    msg(str(text("Working."), ",", use("t1", "add", "{\"a\":2,\"b\":3}"), ",", use("t2", "add", "{\"a\":1}"),
            ",", use("t3", "nope", "{}"), ",", use("t4", "danger", "{}"), ",", use("t5", "broken", "{}"),
            ",", use("t6", "add", "[1,2]")), "tool_use");
    msg(text("Done: 5."), "end_turn");
    show(agent::run(c, p, conv, agent::Limits { .. }, hook, tools));
    skip_seen(1);
    seen_messages(2);
    print("  last text: ", inference::last_text(conv));

    print("-- max_turns, then resumed");
    conv.clear();
    inference::user(conv, "Loop.");
    msg(use("a1", "add", "{\"a\":1,\"b\":1}"), "tool_use");
    msg(use("a2", "add", "{\"a\":2,\"b\":2}"), "tool_use");
    show(agent::run(c, p, conv, agent::Limits { max_turns: 2, .. }, hook, tools));
    skip_seen(2);
    msg(text("Stopped looping."), "end_turn");
    show(agent::run(c, p, conv, agent::Limits { max_turns: 2, .. }, agent::no_hook, tools));
    seen_messages(3);

    print("-- output budget");
    conv.clear();
    inference::user(conv, "Spend.");
    msg(use("b1", "add", "{\"a\":1,\"b\":2}"), "tool_use", 60);
    msg(use("b2", "add", "{\"a\":3,\"b\":4}"), "tool_use", 60);
    show(agent::run(c, p, conv, agent::Limits { max_output_tokens: 100, .. }, hook, tools));
    skip_seen(2);

    print("-- truncated: no tool runs");
    conv.clear();
    inference::user(conv, "Long.");
    msg(use("x1", "add", "{\"a\":1}"), "max_tokens");
    show(agent::run(c, p, conv, agent::Limits { .. }, hook, tools));
    skip_seen(1);

    print("-- refusal");
    conv.clear();
    inference::user(conv, "Something it declines.");
    msg(text(""), "refusal");
    show(agent::run(c, p, conv, agent::Limits { .. }, hook, tools));
    skip_seen(1);

    print("-- pause_turn resumes with nothing added");
    conv.clear();
    inference::user(conv, "Search.");
    msg("{\"type\":\"server_tool_use\",\"id\":\"srv1\",\"name\":\"web_search\",\"input\":{\"query\":\"q\"}}", "pause_turn");
    msg(text("Found it."), "end_turn");
    show(agent::run(c, p, conv, agent::Limits { .. }, hook, tools));
    skip_seen(1);
    seen_messages(0);

    print("-- error");
    c.max_retries = 0;
    reply(400, "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad\"}}");
    show(agent::run(c, p, conv, agent::Limits { .. }, hook, tools));
    skip_seen(1);

    print("-- a hook stops the run");
    conv.clear();
    inference::user(conv, "Go.");
    stop_at_turn = 2;
    msg(use("h1", "add", "{\"a\":5,\"b\":5}"), "tool_use");
    show(agent::run(c, p, conv, agent::Limits { .. }, hook, tools));
    skip_seen(1);
    stop_at_turn = 0;

    print("-- over an OpenAI-compatible provider");
    var o = inference::openai("", base);
    o.provider.tokens_field = "max_tokens";
    conv.clear();
    inference::user(conv, "Add.");
    reply(200, """
        {"id":"c1","model":"local","choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant",
          "content":"Calling.","tool_calls":[
            {"id":"call_1","type":"function","function":{"name":"add","arguments":"{\"a\":20,\"b\":22}"}},
            {"id":"call_2","type":"function","function":{"name":"add","arguments":"{bad"}}]}}],
         "usage":{"prompt_tokens":50,"completion_tokens":9}}
        """);
    reply(200, """
        {"id":"c2","model":"local","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant",
          "content":"42."}}],"usage":{"prompt_tokens":70,"completion_tokens":2}}
        """);
    show(agent::run(o, inference::Params { model: "local", tools: TOOLS, .. }, conv, agent::Limits { .. },
                    agent::print_hook, tools));
    skip_seen(1);
    seen_messages(1);
}

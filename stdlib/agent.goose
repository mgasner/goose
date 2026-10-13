// Agent: a small tool-using loop over inference. Send the conversation, run
// the tools the model asks for, send their results, until a stop
// condition. See docs/inference.md (§4) and docs/design/inference.md.
//
//     let r = agent::run(c, params, conv, agent::Limits { .. }, agent::no_hook) { call, out =>
//         if call.name == "add" { format(out, call.input.get("a").int() + call.input.get("b").int()); return true; }
//         out.append("no such tool");
//         false
//     };

namespace agent;

import std;
import json;
import inference;

struct Limits {
    max_turns: i64 = 20,           // requests in one run
    max_output_tokens: i64 = 0,    // across the run; 0 for no limit
}

let STOP_DONE = 1;         // the model ended its turn
let STOP_TURNS = 2;        // max_turns requests were made
let STOP_BUDGET = 3;       // max_output_tokens were spent
let STOP_TRUNCATED = 4;    // a reply was cut off at max_tokens; its tool calls were not run
let STOP_REFUSAL = 5;      // the model declined
let STOP_ERROR = 6;        // a request failed; run.res says why
let STOP_HOOK = 7;         // a hook said stop

fn stop_name(stop: i64) -> const u8[:] {
    match stop {
        STOP_DONE => "done",
        STOP_TURNS => "turns",
        STOP_BUDGET => "budget",
        STOP_TRUNCATED => "truncated",
        STOP_REFUSAL => "refusal",
        STOP_ERROR => "error",
        STOP_HOOK => "hook",
        _ => "none",
    }
}

// What a run did.
struct Run {
    stop: i64 = 0,
    turns: i64 = 0,
    tool_calls: i64 = 0,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    res: inference::Response = inference::Response { .. },    // the last request's
}

// A tool call, as the tools function and hooks see it. `input` is parsed;
// `text` is the same input as JSON text.
struct Call {
    id: const u8[:],
    name: const u8[:],
    input: json::Value,
    text: const u8[:],
}

enum Event {
    Request { turn: i64 },                                   // before a request; false stops
    Reply { turn: i64, res: const inference::Response& },    // after a reply came
    Tool { call: const Call& },                              // before a call runs; false denies it
    Result { call: const Call&, output: const u8[:], ok: bool },   // after it ran
}

// A hook that lets everything through.
fn no_hook(e: Event) -> bool { true }

// A hook that prints each step, for following a run.
fn print_hook(e: Event) -> bool {
    match e {
        Request r => print("[agent] request ", r.turn),
        Reply r => print("[agent] reply ", r.turn, ": ", r.res.stop_reason, ", ", r.res.input_tokens,
                         " in, ", r.res.output_tokens, " out"),
        Tool t => print("[agent] call ", t.call.name, " ", t.call.text),
        Result r => print("[agent] ", if r.ok { "result " } else { "error " }, r.call.name, ": ", r.output),
    }
    return true;
}

// Runs the conversation until the model is done or a limit is reached.
// The conversation ends either with the model's reply or with tool
// results, so a run that stopped on a limit continues with another run.
//
// tools(call: Call, out: u8[>..]&) -> bool appends its result to out, and
// returns false to mark it an error. hook(e: Event) -> bool sees each step.
fn run<P, H, T>(c: inference::Client<P>&, p: inference::Params, conv: inference::Item..[>..]&,
                limits: Limits) -> Run {
    var r = Run { .. };
    loop {
        guard r.turns < limits.max_turns else { r.stop = STOP_TURNS; break; }
        guard H(Event.Request { turn: r.turns + 1 }) else { r.stop = STOP_HOOK; break; }
        r.turns += 1;
        let sent = inference::send(c, p, conv, r.res);
        r.input_tokens += r.res.input_tokens;
        r.output_tokens += r.res.output_tokens;
        guard sent else { r.stop = STOP_ERROR; break; }
        guard H(Event.Reply { turn: r.turns, res: r.res }) else { r.stop = STOP_HOOK; break; }
        let stop = r.res.stop;
        if stop == inference::STOP_MAX_TOKENS { r.stop = STOP_TRUNCATED; break; }
        if stop == inference::STOP_REFUSAL { r.stop = STOP_REFUSAL; break; }
        if stop == inference::STOP_TOOL_USE {
            let n = answer_calls(p, conv, H, T);
            // A tool_use stop with no calls in it has nothing to answer.
            if n == 0 { r.stop = STOP_DONE; break; }
            r.tool_calls += n;
        } else if stop != inference::STOP_PAUSE {
            r.stop = STOP_DONE;
            break;
        }
        if limits.max_output_tokens > 0 && r.output_tokens >= limits.max_output_tokens {
            r.stop = STOP_BUDGET;
            break;
        }
    }
    return r;
}

// Answers every tool call of the last assistant message, in one user
// message. Returns how many there were.
fn answer_calls<H, T>(p: inference::Params, conv: inference::Item..[>..]&) -> i64 {
    var results: inference::Item..[>..] = [];
    var n = 0;
    inference::each_call(conv) { id, name, input =>
        n++;
        var out: u8[>..] = [];
        let ok = call_tool(p, id, name, input, out, H, T);
        results.push(inference::Item.ToolResult { id: id, content: out[..], is_error: !ok });
    };
    if n > 0 {
        conv.push(inference::Item.User);
        for x in results { conv.push(copy(x)); }
    }
    return n;
}

fn call_tool<H, T>(p: inference::Params, id: const u8[:], name: const u8[:], input: const u8[:],
                   out: u8[>..]&) -> bool {
    let text = if input.len > 0 { input } else { "{}" };
    let d = json::parse(text);
    let call = Call { id: id, name: name, input: d.root(), text: text };
    let ok = block {
        let tool = p.tools.find() { it.name == name };
        guard tool else {
            out.append(str("unknown tool: ", name));
            break false;
        }
        guard d.ok() && d.root().is_object() else {
            out.append("invalid input: not a JSON object");
            break false;
        }
        let missing = missing_property(tool.schema, d.root());
        guard missing.len == 0 else {
            out.append(str("invalid input: missing required property \"", missing, "\""));
            break false;
        }
        guard H(Event.Tool { call: call }) else {
            out.append("denied: this call was not allowed");
            break false;
        }
        T(call, out)
    };
    H(Event.Result { call: call, output: out[..], ok: ok });
    return ok;
}

// The first property the schema lists as required that the input lacks;
// "" if none.
fn missing_property(schema: const u8[:], input: json::Value) -> u8[>..] {
    var out: u8[>..] = [];
    guard schema.len > 0 else { return out; }
    let s = json::parse(schema);
    s.root().get("required").each() { k =>
        if out.len == 0 && !input.get(k.string()).exists() { out.append(k.string()); }
    };
    return out;
}

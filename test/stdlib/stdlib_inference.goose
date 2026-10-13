// runtime-debug: stdlib/inference.goose, offline: requests as each provider writes them,
// then a mock provider on an ephemeral port (mock/provider.goose) for
// replies, block replay, retries, errors, the OpenAI shapes and a
// provider the program declares itself.
import std;
import http;
import json;
import inference;
import mock.provider;

fn show(ok: bool, res: inference::Response&) {
    print("  sent=", ok, " status=", res.status, " attempts=", res.attempts, " stop=", res.stop, " (",
          res.stop_reason, ") id=", res.id, " model=", res.model, " tokens=", res.input_tokens, "/",
          res.output_tokens, " cache=", res.cache_read_tokens, "/", res.cache_write_tokens,
          " error=[", res.error_type, "] ", res.error);
}

fn show_conv(conv: inference::Item..[>..]&) {
    for it in conv {
        match it {
            User => print("  user"),
            Assistant => print("  assistant"),
            Text t => print("    text \"", t.text, "\" raw=", t.raw.len > 0),
            ToolCall c => print("    call ", c.id, " ", c.name, " ", c.input),
            ToolResult r => print("    result ", r.id, " \"", r.content, "\" error=", r.is_error),
            Opaque o => print("    ", o.kind, " ", o.raw),
        }
    }
}

// --- a provider the program brings ---------------------------------------------

// A made-up API: {"prompt": the last user text} in, {"completion": text} out.
struct Echo { key_header: u8[..32] = "X-Echo-Key" }

fn inference_path(p: Echo) -> const u8[:] { "/complete" }

fn inference_headers(p: Echo, api_key: const u8[:], out: u8[>..]&) {
    format(out, p.key_header, ": ", api_key, "\r\n");
}

fn inference_encode(p: Echo, params: inference::Params, conv: inference::Item..[>..]&, out: u8[>..]&) {
    var last: u8[>..] = [];
    for it in conv {
        match it {
            Text t => { last.clear(); last.append(t.text); },
            _ => {},
        }
    }
    var w = json::writer(out);
    w.object() { w.field("prompt", last[..]); };
}

fn inference_decode(p: Echo, body: const u8[:], conv: inference::Item..[>..]&,
                    res: inference::Response&) -> bool {
    let d = json::parse(body);
    let text, ok = d.root().get("completion").try_string();
    guard ok else { return inference::fail(res, "malformed", "no completion"); }
    conv.push(inference::Item.Assistant);
    conv.push(inference::Item.Text { text: text, raw: "" });
    res.stop = inference::STOP_END;
    return true;
}

fn valid(text: const u8[:]) -> bool {
    let d = json::parse(text);
    return d.ok();
}

// --- requests, offline ------------------------------------------------------------

fn encode_tests() {
    print("-- encode");
    var conv: inference::Item..[>..] = [];
    inference::user(conv, "What is 2+3? \"quoted\"\n");
    conv.push(inference::Item.User);                 // a second marker: the same message
    conv.push(inference::Item.Text { text: "And be brief.", raw: "" });
    conv.push(inference::Item.Assistant);
    conv.push(inference::Item.Opaque { kind: "thinking", raw: "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"sig==\"}" });
    conv.push(inference::Item.Text { text: "Adding.", raw: "" });
    conv.push(inference::Item.ToolCall { id: "toolu_1", name: "add", input: "{\"a\":2,\"b\":3}", raw: "" });
    conv.push(inference::Item.ToolCall { id: "toolu_2", name: "add", input: "", raw: "" });
    conv.push(inference::Item.User);
    conv.push(inference::Item.ToolResult { id: "toolu_1", content: "5", is_error: false });
    conv.push(inference::Item.ToolResult { id: "toolu_2", content: "missing a and b", is_error: true });
    conv.push(inference::Item.Assistant);              // an empty message: left out
    conv.push(inference::Item.User);
    conv.push(inference::Item.Text { text: "Thanks", raw: "" });
    let tools: inference::Tool[] = [
        inference::Tool { name: "add", description: "Adds two integers.",
                          schema: "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]}" },
        inference::Tool { name: "now" },
    ];
    let p = inference::Params { system: "You add.", tools: tools, effort: "low", max_tokens: 1024,
                                extra: "\"metadata\":{\"user_id\":\"u1\"}", .. };
    var out: u8[>..] = [];
    inference_encode(inference::Anthropic { .. }, p, conv, out);
    print("anthropic ", out);
    print("  valid JSON: ", valid(out));
    out.clear();
    inference_encode(inference::OpenAI { tokens_field: "max_tokens" }, p, conv, out);
    print("openai ", out);
    print("  valid JSON: ", valid(out));
    out.clear();
    inference_encode(inference::Anthropic { .. }, inference::Params { cache: false, .. }, conv, out);
    print("anthropic, no tools or cache: ", find(out, "\"tools\"") < 0 && find(out, "cache_control") < 0);
    print("last text: ", inference::last_text(conv).len, " (no assistant text after the last user turn)");
}

// --- against the mock -------------------------------------------------------------

fn anthropic_tests(base: const u8[:]) {
    print("-- anthropic");
    var c = inference::anthropic("sk-test", base);
    c.provider.beta = "beta-a,beta-b";
    c.retry_ms = 1;
    var conv: inference::Item..[>..] = [];
    var res = inference::Response { .. };
    inference::user(conv, "Hi");

    reply(200, """
        {"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5-5",
         "content":[{"type":"text","text":"Hello! é"}],
         "stop_reason":"end_turn","stop_sequence":null,
         "usage":{"input_tokens":12,"output_tokens":4,"cache_read_input_tokens":0,"cache_creation_input_tokens":10}}
        """);
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen();
    print("  last text: ", inference::last_text(conv));

    // Thinking, a server tool, a cited text block and two tool calls: every
    // block comes back to the API exactly as it came.
    inference::user(conv, "Add 2 and 3, and 4 and 5.");
    reply(200, """
        {"id":"msg_02","type":"message","role":"assistant","model":"claude-opus-5-5",
         "content":[
           {"type":"thinking","thinking":"","signature":"EqQBCkYIBxgCKkB+/sig=="},
           {"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"sums"}},
           {"type":"text","text":"Sure.","citations":[{"type":"char_location","cited_text":"x","document_index":0,"start_char_index":0,"end_char_index":1}]},
           {"type":"tool_use","id":"toolu_A","name":"add","input":{"a":2,"b":3}},
           {"type":"tool_use","id":"toolu_B","name":"add","input":{"a":4,"b":5,"note":"café \"x\""}}],
         "stop_reason":"tool_use","usage":{"input_tokens":30,"output_tokens":50}}
        """);
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen();
    var calls = 0;
    inference::each_call(conv) { id, name, input => calls++; print("  call ", id, " ", name, " ", input); };
    conv.push(inference::Item.User);
    conv.push(inference::Item.ToolResult { id: "toolu_A", content: "5", is_error: false });
    conv.push(inference::Item.ToolResult { id: "toolu_B", content: "9", is_error: false });
    reply(200, """
        {"id":"msg_03","type":"message","role":"assistant","model":"claude-opus-5-5",
         "content":[{"type":"text","text":"5 and 9."}],"stop_reason":"end_turn",
         "usage":{"input_tokens":60,"output_tokens":5,"cache_read_input_tokens":40}}
        """);
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen();
    show_conv(conv);

    print("-- retries and errors");
    // Overloaded, then fine: retried, waiting what retry-after says.
    reply(529, "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
          "Retry-After: 0");
    reply(200, "{\"id\":\"msg_04\",\"type\":\"message\",\"model\":\"m\",\"content\":[],\"stop_reason\":\"end_turn\",\"usage\":{}}");
    inference::user(conv, "again");
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen_again();
    seen_again();
    let before = conv.len;
    // A bad request is not retried.
    reply(400, "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"messages: roles must alternate\"},\"request_id\":\"req_1\"}");
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen_again();
    // Rate limited past the retries.
    c.max_retries = 1;
    reply(429, "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}");
    reply(429, "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}");
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen_again();
    seen_again();
    // A server error with a body that is not the API's.
    c.max_retries = 0;
    reply(502, "<html>bad gateway</html>");
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen_again();
    // 200, but not a message.
    reply(200, "{\"type\":\"message\",\"content\":");
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen_again();
    reply(200, "{\"type\":\"completion\"}");
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen_again();
    print("  failed sends added nothing: ", conv.len == before);

    var dead = inference::anthropic("k", "http://127.0.0.1:1");
    dead.max_retries = 0;
    show(inference::send(dead, inference::Params { .. }, conv, res), res);
    var tls = inference::anthropic("k");
    show(inference::send(tls, inference::Params { .. }, conv, res), res);
    var odd = inference::anthropic("k", "ftp://x");
    show(inference::send(odd, inference::Params { .. }, conv, res), res);
}

fn openai_tests(base: const u8[:]) {
    print("-- openai");
    var c = inference::openai("sk-oai", str(base, "/"));
    var conv: inference::Item..[>..] = [];
    var res = inference::Response { .. };
    inference::user(conv, "Add 2 and 3.");
    let tools: inference::Tool[] = [inference::Tool { name: "add", schema: "{\"type\":\"object\"}" }];
    let p = inference::Params { model: "gpt-test", tools: tools, .. };
    reply(200, """
        {"id":"chatcmpl-1","object":"chat.completion","model":"gpt-test",
         "choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
           "tool_calls":[{"id":"call_1","type":"function","function":{"name":"add","arguments":"{\"a\":2,\"b\":3}"}}]}}],
         "usage":{"prompt_tokens":20,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":16}}}
        """);
    show(inference::send(c, p, conv, res), res);
    seen();
    conv.push(inference::Item.User);
    conv.push(inference::Item.ToolResult { id: "call_1", content: "5", is_error: false });
    reply(200, """
        {"id":"chatcmpl-2","model":"gpt-test","choices":[{"index":0,"finish_reason":"stop",
          "message":{"role":"assistant","content":"It is 5."}}],"usage":{"prompt_tokens":30,"completion_tokens":4}}
        """);
    show(inference::send(c, p, conv, res), res);
    seen();
    print("  last text: ", inference::last_text(conv));
    reply(200, """
        {"id":"chatcmpl-3","model":"gpt-test","choices":[{"index":0,"finish_reason":"length",
          "message":{"role":"assistant","content":"It is","refusal":null}}],"usage":{}}
        """);
    show(inference::send(c, p, conv, res), res);
    seen_again();
    reply(401, "{\"error\":{\"message\":\"Incorrect API key provided\",\"type\":\"invalid_request_error\",\"code\":\"invalid_api_key\"}}");
    show(inference::send(c, p, conv, res), res);
    seen_again();
    show_conv(conv);
}

fn plugin_tests(base: const u8[:]) {
    print("-- a provider of the program's own");
    var c = inference::Client<Echo> { provider: Echo { .. }, base_url: base, api_key: "e-key", .. };
    var conv: inference::Item..[>..] = [];
    var res = inference::Response { .. };
    inference::user(conv, "ping");
    reply(200, "{\"completion\":\"pong\"}");
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen();
    print("  last text: ", inference::last_text(conv));
    // Its error bodies go through the shared reader.
    reply(503, "{\"error\":{\"type\":\"unavailable\",\"message\":\"try later\"}}");
    c.max_retries = 0;
    show(inference::send(c, inference::Params { .. }, conv, res), res);
    seen();
}

fn main() {
    encode_tests();
    let base = start_mock();
    anthropic_tests(base);
    openai_tests(base);
    plugin_tests(base);
}

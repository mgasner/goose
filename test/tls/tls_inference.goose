// stdlib/inference.goose and stdlib/agent.goose over https://: a mock
// Anthropic provider served with serve_tls on an ephemeral port and the
// test-only certificates in test/tls/certs/ (README there), the client
// trusting the test CA through its http::Client's ca_file. One send, one
// agent run that calls a tool, and a client on the system's CAs, which
// rejects the test certificate. Runs only where the compiler has TLS built
// in; everything is local, and no real API is called.
import std;
import http;
import json;
import inference;
import agent;

struct Seen { path: u8[], key: u8[], body: u8[] }

// Answers each request with the next reply queued with qput<u8[]>, and hands
// what it got back on the Seen queue.
fn answer(req: http::Request&, res: http::Response&) {
    let key, ok = http::header(req, "x-api-key");
    qput(Seen { path: req.path, key: if ok { key } else { "" }, body: req.body });
    res.content_type = "application/json";
    res.body.append(qget<u8[]>());
}

thread_fn mock(listener: i64) {
    if !http::serve_tls_on(listener, "test/tls/certs/server.pem", "test/tls/certs/server.key",
                           http::Limits { max_body: 1 << 20, .. }, answer) {
        var why: u8[>..] = [];
        http::tls_error(why);
        print("serve_tls_on failed: ", why);
    }
}

fn msg(id: const u8[:], content: const u8[:], stop: const u8[:]) {
    let body: u8[] = str("{\"id\":\"", id, "\",\"type\":\"message\",\"model\":\"claude-test\",\"content\":[",
                         content, "],\"stop_reason\":\"", stop,
                         "\",\"usage\":{\"input_tokens\":12,\"output_tokens\":5}}");
    qput(body);
}

fn seen() {
    let s = qget<Seen>();
    print("  POST ", s.path, " key=", s.key, " ", s.body);
}

fn show(ok: bool, res: inference::Response&) {
    print("  sent=", ok, " status=", res.status, " attempts=", res.attempts, " stop=", res.stop_reason,
          " id=", res.id, " tokens=", res.input_tokens, "/", res.output_tokens,
          " error=[", res.error_type, "] ", res.error);
}

fn tools(call: agent::Call, out: u8[>..]&) -> bool {
    if call.name == "add" {
        format(out, call.input.get("a").int() + call.input.get("b").int());
        return true;
    }
    out.append("no such tool");
    return false;
}

fn main() {
    print("tls available: ", http::tls_available());
    let l = http::listen(0, "127.0.0.1");
    thread_spawn(mock, l);
    let base = str("https://localhost:", http::listener_port(l));

    print("-- send");
    var c = inference::anthropic("sk-test", base);
    c.http.ca_file = "test/tls/certs/ca.pem";
    var conv: inference::Item..[>..] = [];
    var res = inference::Response { .. };
    inference::user(conv, "Say hello.");
    msg("msg_1", "{\"type\":\"text\",\"text\":\"Hello over TLS.\"}", "end_turn");
    show(inference::send(c, inference::Params { model: "claude-test", max_tokens: 100, .. }, conv, res), res);
    seen();
    print("  last text: ", inference::last_text(conv), " tls=", c.http.tls >= 0);

    print("-- agent run");
    let tool_list: inference::Tool[] = [
        inference::Tool { name: "add", description: "Adds two integers.",
                          schema: "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]}" },
    ];
    let p = inference::Params { model: "claude-test", max_tokens: 100, tools: tool_list, .. };
    conv.clear();
    inference::user(conv, "Add 2 and 3.");
    msg("msg_2", "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"add\",\"input\":{\"a\":2,\"b\":3}}", "tool_use");
    msg("msg_3", "{\"type\":\"text\",\"text\":\"5.\"}", "end_turn");
    let r = agent::run(c, p, conv, agent::Limits { .. }, agent::print_hook, tools);
    print("  run: stop=", agent::stop_name(r.stop), " turns=", r.turns, " calls=", r.tool_calls,
          " tokens=", r.input_tokens, "/", r.output_tokens, " error=", r.res.error);
    qget<Seen>();
    seen();
    print("  last text: ", inference::last_text(conv));
    http::close(c.http);

    print("-- the system's CAs");
    // They do not include the test CA, so the handshake fails, and the
    // request never reaches the mock. A certificate error is not retried
    // away: max_retries 0 keeps the test quick.
    var sys = inference::anthropic("sk-test", base);
    sys.max_retries = 0;
    let before = conv.len;
    show(inference::send(sys, inference::Params { .. }, conv, res), res);
    print("  added nothing: ", conv.len == before);
}

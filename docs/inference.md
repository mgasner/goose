# Model APIs and agents in Goose

`import inference;` sends conversations to model provider APIs: the
Anthropic Messages API, and OpenAI-compatible Chat Completions (OpenAI
itself, vLLM, llama.cpp, Ollama, ...). A program can add a provider of its
own. `import agent;` runs a tool-using agent over it: send, run the tools
the model asks for, send the results, until a stop condition.

Both are written in Goose, over [`http`](http.md) and [`json`](json.md).
The design and its reasons are in
[`design/inference.md`](design/inference.md).

**HTTPS.** Every hosted provider is HTTPS-only, and the default base URLs
are `https://`. They work when the program has TLS: the compiler was built
with Mbed TLS and the program is run in-process, or its C was linked with
what `goose --tls-link cc` names ([`http.md`](http.md) §3 has the build).
The client verifies the provider's certificate against the system's CAs,
or against the PEM bundle in `c.http.ca_file`. Without TLS, an `https://`
request fails at once with `http`'s own error, which says how to build
with it, and is not retried. Local servers that speak plain HTTP (vLLM,
llama.cpp, Ollama) take an `http://` base URL, as does a TLS-terminating
proxy where TLS is not built (Windows). Requests are not streamed, since
`http::fetch` reads whole responses.

---

## 1. One request

```goose
import std;
import os;
import inference;

fn main() {
    var key: u8[>..] = [];
    env("ANTHROPIC_API_KEY", key);
    var c = inference::anthropic(key);   // https://api.anthropic.com

    var conv: inference::Item..[>..] = [];
    inference::user(conv, "Name three rivers in France.");
    var res = inference::Response { .. };
    if !inference::send(c, inference::Params { max_tokens: 1024, .. }, conv, res) {
        print("failed: ", res.error_type, ": ", res.error);
        return;
    }
    print(inference::last_text(conv));
    print(res.input_tokens, " tokens in, ", res.output_tokens, " out");
}
```

`send` writes the request, POSTs it, and on success appends the model's
reply to `conv`. Send again to continue the conversation: add a user
message with `inference::user`, or tool results (§3).

## 2. Requests

```goose
struct Params {
    model: const u8[:] = "claude-opus-5-5",
    max_tokens: i64 = 16000,
    system: const u8[:] = "",
    tools: const Tool[:],           // none unless given
    effort: const u8[:] = "",       // "low" ... "max"; "" leaves the model's default
    cache: bool = true,             // Anthropic: automatic prompt caching
    extra: const u8[:] = "",        // more top-level members, written as is
}
struct Tool { name: const u8[:], description: const u8[:] = "", schema: const u8[:] = "" }
```

`schema` is the tool's input JSON Schema as JSON text. `extra` is any
other top-level members, as JSON text without braces, for what `Params`
does not name:

```goose
let p = inference::Params {
    system: "You are terse.",
    effort: "high",
    extra: "\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"},\"metadata\":{\"user_id\":\"u1\"}",
    ..
};
```

With Anthropic, `effort` is `output_config.effort` and `cache` adds the
top-level `cache_control` that caches the longest prefix it can. With
OpenAI-compatible servers, `effort` is `reasoning_effort` and `cache` does
nothing.

## 3. Conversations

```goose
enum Item {
    User,                                         // a user message starts here
    Assistant,                                    // an assistant message starts here
    Text { text: u8[], raw: u8[] },
    ToolCall { id: u8[], name: u8[], input: u8[], raw: u8[] },   // input: JSON text
    ToolResult { id: u8[], content: u8[], is_error: bool },
    Opaque { kind: u8[..40], raw: u8[] },         // a block this library does not decode
}
```

A conversation is a flat array: a role marker, then the message's blocks.
Two markers of one role in a row are one message, and an empty message is
left out, so appending never breaks the alternation the APIs require.

A block that came from the provider keeps its exact JSON in `raw`, and is
sent back as it came. Thinking blocks and their signatures, server-tool
blocks, citations: all of it survives every turn without the program doing
anything. Blocks the library does not decode are `Opaque`, with their
`type` in `kind`.

Answering tool calls is appending results:

```goose
inference::each_call(conv) { id, name, input =>
    // run the tool ...
};
conv.push(inference::Item.User);
conv.push(inference::Item.ToolResult { id: "toolu_01", content: "42", is_error: false });
```

Answer every call of a reply in one user message, as above; the agent loop
(§5) does this for you. Other helpers:

| Call | |
|---|---|
| `inference::user(conv, text)` | append a user message of one text block |
| `inference::last_text(conv) -> u8[>..]` | the last assistant message's text |
| `inference::each_call(conv) { id, name, input => … }` | the last assistant message's tool calls |
| `inference::last_assistant(conv) -> i64` | where that message starts, in items; -1 if none |

A conversation is plain data: `conv.to_bytes()` saves it, and
`from_bytes<inference::Item..[>..]>` loads it.

## 4. Responses and errors

```goose
struct Response {
    status: i64,                   // HTTP status of the last attempt; 0 if none came
    attempts: i64,
    stop: i64,                     // inference::STOP_*
    stop_reason: u8[..40],         // as the provider gave it
    id: u8[..100], model: u8[..100],
    input_tokens: i64, output_tokens: i64, cache_read_tokens: i64, cache_write_tokens: i64,
    error_type: u8[..60],          // "rate_limit_error", "transport", "malformed", ...
    error: u8[..400],              // "" when the call worked
}
```

| `stop` | Anthropic | OpenAI |
|---|---|---|
| `STOP_END` | `end_turn`, `stop_sequence` | `stop` |
| `STOP_TOOL_USE` | `tool_use` | `tool_calls` |
| `STOP_MAX_TOKENS` | `max_tokens`, `model_context_window_exceeded` | `length` |
| `STOP_PAUSE` | `pause_turn`: send again, adding nothing | |
| `STOP_REFUSAL` | `refusal` | `content_filter`, or a `refusal` message |
| `STOP_OTHER` | anything else | anything else |

`send` retries 408, 409, 429 and 5xx (Anthropic's 529 included) and
connection failures, `max_retries` times (2 by default), waiting
`retry_ms` (500) and doubling, or what a `retry-after` header says. Other
failures are not retried. A failed send adds nothing to the conversation.
The error type and message come from the API's error body when there is
one.

```goose
struct Client<P> {
    provider: P,
    base_url: u8[..256],
    api_key: u8[..256],
    http: http::Client,            // timeout_ms is 600000: ten minutes per read
    max_retries: i64 = 2,
    retry_ms: i64 = 500,
}
fn anthropic(api_key, base_url = "https://api.anthropic.com") -> Client<Anthropic>
fn openai(api_key, base_url = "https://api.openai.com") -> Client<OpenAI>
```

`c.provider.beta` sets `anthropic-beta` (comma-separated), and
`c.provider.version` `anthropic-version`. For servers that want
`max_tokens` rather than OpenAI's `max_completion_tokens`, set
`c.provider.tokens_field = "max_tokens"`. An empty `api_key` sends no
authorization header, for local servers.

## 5. Agents

```goose
import std;
import os;
import inference;
import agent;

let TOOLS: inference::Tool[] = [
    inference::Tool { name: "add", description: "Adds two integers.",
                      schema: """{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}""" },
];

fn tools(call: agent::Call, out: u8[>..]&) -> bool {
    if call.name == "add" {
        format(out, call.input.get("a").int() + call.input.get("b").int());
        return true;
    }
    out.append("no such tool");
    return false;                  // an error result
}

fn main() {
    var key: u8[>..] = [];
    env("ANTHROPIC_API_KEY", key);
    var c = inference::anthropic(key);
    var conv: inference::Item..[>..] = [];
    inference::user(conv, "What is 1234 + 4321?");
    let r = agent::run(c, inference::Params { tools: TOOLS, .. }, conv, agent::Limits { .. },
                       agent::print_hook, tools);
    print(agent::stop_name(r.stop), ": ", inference::last_text(conv));
}
```

`agent::run(client, params, conv, limits, hook, tools)` loops: send, run
the reply's tool calls, append their results in one user message, send
again. The tools function can be a block: `agent::run(c, p, conv,
limits, hook) { call, out => … }`.

```goose
struct Call { id: const u8[:], name: const u8[:], input: json::Value, text: const u8[:] }
```

`call.input` is the parsed input (a `json::Value`, §2 of the JSON guide);
`call.text` the same as JSON text. The tools function appends its result
to `out` and returns false to report an error to the model.

**The registry** is `params.tools`. Before the tools function sees a call,
the loop answers with an error result, itself:

* a call to a tool not in `params.tools`;
* input that is not a JSON object;
* input missing a property the tool's schema lists in `required`.

**Hooks.** `hook(e: agent::Event) -> bool` sees each step:

```goose
enum Event {
    Request { turn: i64 },                                   // before a request; false stops
    Reply { turn: i64, res: const inference::Response& },    // after a reply; false stops
    Tool { call: const Call& },                              // before a call; false denies it
    Result { call: const Call&, output: const u8[:], ok: bool },
}

fn approve(e: agent::Event) -> bool {
    match e {
        Tool t => t.call.name != "delete_everything",
        _ => true,
    }
}
```

A denied call gets an error result saying so, and the run goes on.
`agent::no_hook` allows everything; `agent::print_hook` prints each step.

**Stopping.**

```goose
struct Limits { max_turns: i64 = 20, max_output_tokens: i64 = 0 }   // 0: no budget
struct Run { stop: i64, turns: i64, tool_calls: i64, input_tokens: i64, output_tokens: i64,
             res: inference::Response }
```

| `r.stop` | when |
|---|---|
| `agent::STOP_DONE` | the model ended its turn |
| `agent::STOP_TURNS` | `max_turns` requests were made |
| `agent::STOP_BUDGET` | the run's output tokens reached `max_output_tokens` |
| `agent::STOP_TRUNCATED` | a reply hit `max_tokens`; its tool calls were not run, since a cut-off input may still parse |
| `agent::STOP_REFUSAL` | the model declined |
| `agent::STOP_ERROR` | a request failed; `r.res` says why |
| `agent::STOP_HOOK` | a hook returned false for a request or a reply |

The limits are checked after a turn's tool results are appended, so a run
stopped by `STOP_TURNS`, `STOP_BUDGET` or `STOP_HOOK` continues with
another `run` on the same conversation. `pause_turn` is handled inside the
run: it sends again with nothing added. After `STOP_TRUNCATED` the last
message has unanswered tool calls; send again with a larger `max_tokens`
after removing that message, or answer the calls.

Tools run one at a time on the calling thread. To run them in parallel,
hand them to workers through queues inside the tools function.

## 6. A provider of your own

A provider is a type and five functions, declared in the global namespace
(not in a namespace of your own), which `send` picks by the type:

```goose
struct Echo { }

fn inference_path(p: Echo) -> const u8[:] { "/complete" }
fn inference_headers(p: Echo, api_key: const u8[:], out: u8[>..]&) {
    format(out, "X-Key: ", api_key, "\r\n");          // each header line ends in \r\n
}
fn inference_encode(p: Echo, params: inference::Params, conv: inference::Item..[>..]&, out: u8[>..]&) {
    // write the request body into out
}
fn inference_decode(p: Echo, body: const u8[:], conv: inference::Item..[>..]&,
                    res: inference::Response&) -> bool {
    // read a 2xx body: append an Assistant marker and its blocks to conv,
    // set res.stop and usage; false (inference::fail(res, kind, why)) if malformed
}

var c = inference::Client<Echo> { provider: Echo { }, base_url: "http://127.0.0.1:9000", .. };
```

Errors (non-2xx bodies) are read by a shared `inference_error`, which
understands `{"error":{"type","message"}}`. Declare
`fn inference_error(p: Echo, body: const u8[:], res: inference::Response&)`
for another shape. The agent loop works with any provider.
`test/stdlib/stdlib_inference.goose` has a complete one.

## 7. Testing without a network

`test/stdlib/mock/provider.goose` is a mock provider: an `http` server
worker on an ephemeral port that answers each request with the next canned
reply from a queue and hands every request back on another queue. The
`stdlib_inference` and `stdlib_agent` fixtures use it to check requests
byte for byte and replies of every kind, offline. Threads need the C
backend: build with `goose -o prog.c --standalone prog.goose` and compile
the result. `test/tls/tls_inference.goose` does the same over `https://`:
a mock served with `http::serve_tls` and the test-only certificates in
`test/tls/certs/`, the client trusting their CA through `c.http.ca_file`.
It runs where TLS is built in.

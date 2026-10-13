# Inference client and agent loop

Status: implemented. The libraries are `stdlib/inference.goose` (with
`stdlib/inference/`) and `stdlib/agent.goose`, on `http` and `json`. The
guide is [`../inference.md`](../inference.md). The `stdlib_inference` and
`stdlib_agent` fixtures test them offline against a mock server built with
`http`, and `tls/tls_inference` over `https://` against one served with TLS.

## Goal

Talk to model provider APIs from Goose, and run a tool-using agent on top:

* **`inference`**: one call sends a conversation to a provider and appends
  the model's reply to it. The Anthropic Messages API is first-class. An
  OpenAI-compatible Chat Completions provider ships too, mainly to prove
  that the provider interface holds a second shape.
* **`agent`**: a small loop over `inference`: send, run the tools the model
  asked for, send their results, until a stop condition. Tools and hooks
  are the program's own functions.

## Constraints that shape it

1. **TLS is the transport's.** Every hosted provider is HTTPS-only. The
   client takes a `base_url` and leaves how bytes reach the provider to
   `http`, which speaks `https://` over Mbed TLS when the program has it
   (design/http.md; `goose --tls-link` for C built with `-o`). The client
   adds nothing for TLS: certificate checks and their CAs are its
   `http::Client`'s (`c.http.ca_file`). Without TLS, an `https://` base
   URL fails with `http`'s error, which says how to build with TLS, and
   that failure is not retried. Local OpenAI-compatible servers (vLLM,
   llama.cpp, Ollama) speak plain HTTP and take an `http://` base URL.
2. **No streaming.** `http::fetch` returns whole responses, so requests are
   non-streaming. Long generations must fit in the client's timeout, which
   defaults to 10 minutes; `max_tokens` defaults to 16000 accordingly.
3. **No dynamic dispatch, no closures that escape** (spec §7.6). Function
   values are compile-time arguments. That decides how both "pluggable"
   pieces work (below).
4. **No heap, one resizable per struct.** A conversation cannot be a
   struct owning a list of messages owning lists of blocks. It is one
   grow-only array of variable-size items that the caller owns.

## The conversation

```goose
enum Item {
    User,                                         // a user message starts here
    Assistant,                                    // an assistant message starts here
    Text { text: u8[], raw: u8[] },
    ToolCall { id: u8[], name: u8[], input: u8[], raw: u8[] },   // input: JSON text
    ToolResult { id: u8[], content: u8[], is_error: bool },
    Opaque { kind: u8[..40], raw: u8[] },         // a provider block kept as is
}
var conv: inference::Item..[>..] = [];
```

A conversation is a flat `Item..[>..]`: role markers, each followed by that
message's blocks, every string inline. It is one block of memory, with no
pointers, that `to_bytes` can save. Encoders merge consecutive markers of
one role and skip empty messages, so appending is always safe.

**Blocks are replayed exactly.** A block the provider sent keeps its JSON
in `raw`, and the Anthropic encoder writes `raw` back as it came. That
matters: thinking blocks carry signatures that must come back unchanged,
and server-tool, citation, compaction and fallback blocks have shapes this
library need not know. `Opaque` holds every block type the library does not
decode, so nothing is lost. The fields (`text`, `id`, `name`, `input`) are
decoded for the program's use. Blocks the program writes have no `raw` and
are encoded from their fields. The OpenAI encoder ignores `raw` and
`Opaque`: a conversation's raw blocks belong to the provider that wrote
them.

## Providers

```goose
struct Client<P> { provider: P, base_url, api_key, http: http::Client, max_retries, retry_ms }
fn send<P>(c: Client<P>&, p: Params, conv: Item..[>..]&, res: Response&) -> bool
```

A provider is a type, and its behavior is a set of overloads in the global
namespace, chosen by that type when `send` is instantiated:

```goose
fn inference_path(p: P) -> const u8[:]                                   // "/v1/messages"
fn inference_headers(p: P, api_key: const u8[:], out: u8[>..]&)           // auth, version
fn inference_encode(p: P, params: inference::Params, conv: …, out: u8[>..]&)
fn inference_decode(p: P, body: const u8[:], conv: …&, res: inference::Response&) -> bool
fn inference_error(p: P, body: const u8[:], res: inference::Response&)   // optional
```

The library declares these for `inference::Anthropic` and
`inference::OpenAI`. A program adds a provider by declaring a struct and
these five functions for it; nothing in the library changes. They live in
the global namespace because a generic body resolves names where it is
defined, and an overload set never merges across namespaces (spec §11.1):
the library's `send` sees the program's overloads only if both sit in the
global set. `inference_error` has a generic fallback that reads
`{"error":{"type","message"}}`, the shape both shipped providers use.

This is static dispatch, like the GraphQL module's case functions: a
program that uses one provider compiles one. A program choosing a provider
at run time holds a `Client` of each, or wraps them in an enum.

`send` does what every SDK does around the call: it writes the request,
POSTs it, retries 408, 409, 429, 5xx and connection failures with
exponential backoff (honoring `retry-after`), reads the error type and
message of a failed call into `res`, and on success appends the assistant
message to `conv` and fills in `res`: the stop reason, normalized to
`STOP_END`, `STOP_TOOL_USE`, `STOP_MAX_TOKENS`, `STOP_PAUSE`,
`STOP_REFUSAL` or `STOP_OTHER`, the raw reason, ids and token usage.

### Anthropic

`POST {base}/v1/messages` with `x-api-key` and `anthropic-version:
2023-06-01`, and `anthropic-beta` when the provider lists betas. The body
has `model` (default `claude-opus-5-5`), `max_tokens`, `system`, `tools`
(`name`, `description`, `input_schema`), `output_config.effort` when set,
top-level `cache_control` (automatic prompt caching, on by default: an
agent resends a growing prefix every turn), `extra` members as given, and
`messages`. Thinking is left to the model's default (adaptive on the
current models); `extra` is the way to set it, or anything else.

### OpenAI-compatible

`POST {base}/v1/chat/completions` with `Authorization: Bearer`. A system
message comes first. A user turn becomes `tool` messages for its tool
results, then one user message for its text. An assistant turn becomes
one message with `content` and `tool_calls`, whose `arguments` is the input
JSON as a string. `effort` is `reasoning_effort`. The token-limit field is
configurable: `max_completion_tokens` for OpenAI, `max_tokens` for most
local servers. `finish_reason` maps to the same stop codes.

## The agent loop

```goose
fn run<P, H, T>(c: inference::Client<P>&, p: inference::Params,
                conv: inference::Item..[>..]&, limits: Limits, hook: H, tools: T) -> Run
```

Called as `agent::run(c, params, conv, limits, hook) { call, out => … }`.
Each turn:

1. `hook(Event.Request)`; false stops (`STOP_HOOK`).
2. `send`. A failure stops (`STOP_ERROR`), with the response in the run.
3. `hook(Event.Reply)`.
4. By stop reason: `end_turn` and the like stop (`STOP_DONE`); `refusal`
   stops (`STOP_REFUSAL`); `max_tokens` stops (`STOP_TRUNCATED`) without
   running any tool, since a cut-off tool input may still parse;
   `pause_turn` sends again with nothing added, which resumes the server's
   tool loop.
5. For `tool_use`, every call of the reply is answered, in order, in one
   user message: parallel calls stay parallel in the transcript.
   * A name not among `params.tools` gets an error result without
     calling the program (the registry is the tool list it already sends).
   * Input that is not a JSON object, or lacks a property the tool's schema
     lists as `required`, gets an error result too.
   * `hook(Event.Tool)` may deny a call: false gives the model an error
     result saying so.
   * Otherwise `tools(call, out)` runs: it appends its result to `out` and
     returns false to mark it an error. `hook(Event.Result)` sees it.
6. Limits: `max_turns` requests (`STOP_TURNS`) and `max_output_tokens`
   across the run (`STOP_BUDGET`) are checked after the results are
   appended, so the conversation is always resumable: call `run` again.

A run returns `Run { stop, turns, tool_calls, input_tokens, output_tokens,
res }`. Hooks are one function over an `Event` enum, so a program handles
the events it cares about with a `match` and `_ => true`.
`agent::no_hook` allows everything; `agent::print_hook` traces a run.

Tools run one after another on the calling thread. A program wanting them
in parallel can hand them to workers through queues inside its `tools`
function; the loop does not need to know.

## Testing

Both fixtures run offline. Each starts an `http` server worker on an
ephemeral port that answers with canned responses taken from a queue and
puts every request it gets on another queue, so the test prints exactly
what the client sent (path, headers that matter, and the JSON body) and
what it made of each reply: retries, error bodies, unknown blocks,
thinking signatures replayed byte for byte, tool calls, denied and invalid
calls, every stop condition, and the OpenAI shapes.

`tls/tls_inference` runs a send and an agent run over `https://`, against
a mock served by `http::serve_tls` with the test-only certificates in
`test/tls/certs/`; the client trusts their CA through `c.http.ca_file`. A
client on the system's CAs is refused the test certificate. It runs where
TLS is built in, as the other `tls/` tests do.

## Left open

* **Streaming** (SSE): needs an incremental read in `http::fetch`. The
  event parser itself would be small; the transport is the missing piece.
* Images and documents in user turns: a program can write them as `Opaque`
  blocks with `raw` JSON today, for Anthropic.
* Token counting, batches, the Files API.

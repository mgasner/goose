// What every part of inference shares: the conversation, a request's
// parameters, the response, the client, and helpers over conversations.

namespace inference;

import std;
import http;

// --- the conversation ------------------------------------------------------------

// A conversation is a flat Item..[>..]: a role marker, then that message's
// blocks, then the next marker. Every string is inline. `raw` holds a
// block's JSON exactly as the provider sent it, and is written back as it
// is to that provider; blocks a program makes leave it empty.
enum Item {
    User,
    Assistant,
    Text { text: u8[], raw: u8[] },
    ToolCall { id: u8[], name: u8[], input: u8[], raw: u8[] },   // input: the arguments, JSON
    ToolResult { id: u8[], content: u8[], is_error: bool },
    Opaque { kind: u8[..40], raw: u8[] },     // a block this library does not decode
}

// Appends a user message of one text block.
fn user(conv: Item..[>..]&, text: const u8[:]) {
    conv.push(Item.User);
    conv.push(Item.Text { text: text, raw: "" });
}

// The text of the last assistant message, its text blocks joined.
fn last_text(conv: Item..[>..]&) -> u8[>..] {
    var out: u8[>..] = [];
    var assistant = false;
    for it in conv {
        match it {
            User => { assistant = false; },
            Assistant => {
                if !assistant { out.clear(); }
                assistant = true;
            },
            Text t => { if assistant { out.append(t.text); } },
            _ => {},
        }
    }
    return out;
}

// The position, in items, where the last assistant message starts: its
// first marker. -1 if there is none.
fn last_assistant(conv: Item..[>..]&) -> i64 {
    var at = -1;
    var assistant = false;
    var i = 0;
    for it in conv {
        match it {
            User => { assistant = false; },
            Assistant => {
                if !assistant { at = i; }
                assistant = true;
            },
            _ => {},
        }
        i++;
    }
    return at;
}

// F(id, name, input) for each tool call of the last assistant message.
fn each_call<F>(conv: Item..[>..]&) {
    let start = last_assistant(conv);
    guard start >= 0;
    var i = 0;
    for it in conv {
        if i >= start {
            match it {
                ToolCall c => F(c.id[..], c.name[..], c.input[..]),
                _ => {},
            }
        }
        i++;
    }
}

// --- a request -------------------------------------------------------------------

// A tool the model may call. `schema` is its input's JSON Schema, as JSON
// text; "" is an object with any properties.
struct Tool {
    name: const u8[:],
    description: const u8[:] = "",
    schema: const u8[:] = "",
}

struct Params {
    model: const u8[:] = "claude-opus-5-5",
    max_tokens: i64 = 16000,
    system: const u8[:] = "",
    tools: const Tool[:],           // none by default
    effort: const u8[:] = "",       // "low" ... "max"; "" leaves the model's default
    cache: bool = true,             // Anthropic: automatic prompt caching
    extra: const u8[:] = "",        // more top-level members, written as is: "\"k\":v,\"k2\":v2"
}

// --- a response ------------------------------------------------------------------

let STOP_NONE = 0;           // no reply came
let STOP_END = 1;            // the model finished its turn (or hit a stop sequence)
let STOP_TOOL_USE = 2;       // it wants tool results
let STOP_MAX_TOKENS = 3;     // it was cut off at max_tokens
let STOP_PAUSE = 4;          // a server-side tool loop paused; send again to resume
let STOP_REFUSAL = 5;        // it declined
let STOP_OTHER = 6;

struct Response {
    status: i64 = 0,               // HTTP status of the last attempt; 0 if none came
    attempts: i64 = 0,
    stop: i64 = 0,                 // STOP_*
    stop_reason: u8[..40] = [],    // as the provider gave it
    id: u8[..100] = [],
    model: u8[..100] = [],
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
    error_type: u8[..60] = [],     // "rate_limit_error", "transport", ...
    error: u8[..400] = [],         // "" when the call worked
}

fn ok(res: Response&) -> bool { res.error.len == 0 }

// --- the client --------------------------------------------------------------------

// A connection to one provider. P says which, and its overloads of
// inference_path, _headers, _encode, _decode (and optionally _error) say
// how to speak to it.
struct Client<P> {
    provider: P,
    base_url: u8[..256] = [],
    api_key: u8[..256] = [],
    http: http::Client = http::Client { timeout_ms: 600000, .. },
    max_retries: i64 = 2,          // after the first attempt
    retry_ms: i64 = 500,           // the first backoff; it doubles
}

fn clip(dst: u8[..40]&, s: const u8[:]) { dst.clear(); dst.append(s[..min(s.len, 40)]); }
fn clip(dst: u8[..60]&, s: const u8[:]) { dst.clear(); dst.append(s[..min(s.len, 60)]); }
fn clip(dst: u8[..100]&, s: const u8[:]) { dst.clear(); dst.append(s[..min(s.len, 100)]); }
fn clip(dst: u8[..400]&, s: const u8[:]) { dst.clear(); dst.append(s[..min(s.len, 400)]); }

// Records a failure in res; false, for `return fail(...)`.
fn fail(res: Response&, kind: const u8[:], message: const u8[:]) -> bool {
    clip(res.error_type, kind);
    clip(res.error, if message.len > 0 { message } else { "failed" });
    return false;
}

// Sending a conversation: the request, retries, errors, and the reply
// appended to the conversation. What differs between providers is in the
// inference_* overloads (anthropic.goose, openai.goose).

namespace inference;

import std;
import os;
import http;
import json;

// Sends conv to the model and, on success, appends its reply to conv as an
// assistant message. res says how it went: the stop reason, usage, ids, or
// the error. false, with res.error set, when no reply came.
fn send<P>(c: Client<P>&, p: Params, conv: Item..[>..]&, res: Response&) -> bool {
    res = Response { .. };
    // https:// needs the http package built with TLS (packages/http); without
    // it, the http module's own error comes back as the transport error.
    let https = starts_with(c.base_url[..], "https://");
    guard https || starts_with(c.base_url[..], "http://") else {
        return fail(res, "transport", "base_url is not an http:// or https:// URL");
    }
    var body: u8[>..] = [];
    inference_encode(c.provider, p, conv, body);
    var headers: u8[>..] = [];
    headers.append("Content-Type: application/json\r\n");
    inference_headers(c.provider, c.api_key[..], headers);
    var url: u8[>..] = [];
    url.append(trim_slash(c.base_url[..]));
    url.append(inference_path(c.provider));

    var buf: u8[>..] = [];
    for attempt in c.max_retries + 1 {
        res.attempts = attempt + 1;
        buf.clear();
        var wait = c.retry_ms << min(attempt, 6);
        var retry = true;
        {
            var rep = http::Reply { .. };
            if http::fetch(c.http, "POST", url, buf, rep, body, headers) {
                res.status = rep.status;
                if rep.status >= 200 && rep.status < 300 {
                    clip(res.error_type, "");
                    clip(res.error, "");
                    if inference_decode(c.provider, rep.body, conv, res) { return true; }
                    if res.error.len == 0 { fail(res, "malformed", "the reply is not what the API documents"); }
                    return false;
                }
                inference_error(c.provider, rep.body, res);
                if res.error.len == 0 { fail(res, "http", str("HTTP ", rep.status, " ", rep.reason)); }
                retry = retryable(rep.status);
                let after, has = http::header(rep, "retry-after");
                if has {
                    let s, okn = parse_int(trim(after));
                    if okn && s >= 0 { wait = min(s * 1000, 60000); }
                }
            } else {
                res.status = 0;
                fail(res, "transport", c.http.error);
                retry = !https || http::tls_available();   // no TLS will not change
            }
        }
        if !retry || attempt == c.max_retries { break; }
        sleep_ms(wait);
    }
    return false;
}

// Statuses worth trying again: timeouts, conflicts, rate limits and the
// server's own failures (529 is Anthropic's "overloaded").
fn retryable(status: i64) -> bool {
    status == 408 || status == 409 || status == 429 || status >= 500
}

fn trim_slash(s: const u8[:]) -> const u8[:] {
    if s.len > 0 && s[s.len - 1] == '/' { s[..s.len - 1] } else { s }
}

// The error body most providers send: {"error":{"type":..,"message":..}}.
// OpenAI-style bodies give "code" where the type is null. A provider
// declares its own overload for another shape.
fn ::inference_error<P>(p: P, body: const u8[:], res: inference::Response&) {
    let d = json::parse(body);
    guard d.ok() else { return; }
    let e = d.root().get("error");
    var kind = e.get("type").string();
    if kind.len == 0 { kind = e.get("code").string(); }
    let message = e.get("message").string();
    if kind.len > 0 || message.len > 0 {
        inference::fail(res, if kind.len > 0 { kind } else { "error" }, message);
    }
}

// The JSON text of a parsed value: a block's `raw`, a tool's input.
fn json_text(out: u8[>..]&, v: json::Value) {
    var w = json::writer(out);
    w.value(v);
}

// The Anthropic Messages API: POST /v1/messages.

namespace inference;

import std;
import json;

struct Anthropic {
    version: u8[..16] = "2023-06-01",     // anthropic-version
    beta: u8[..256] = [],                 // anthropic-beta, comma-separated; "" for none
}

// A client for the Anthropic API. The default https:// base URL needs a
// program whose http package has TLS (packages/http).
fn anthropic(api_key: const u8[:], base_url: const u8[:] = "https://api.anthropic.com") -> Client<Anthropic> {
    Client<Anthropic> { provider: Anthropic { .. }, base_url: base_url, api_key: api_key, .. }
}

fn ::inference_path(p: inference::Anthropic) -> const u8[:] { "/v1/messages" }

fn ::inference_headers(p: inference::Anthropic, api_key: const u8[:], out: u8[>..]&) {
    if api_key.len > 0 { format(out, "x-api-key: ", api_key, "\r\n"); }
    format(out, "anthropic-version: ", p.version, "\r\n");
    if p.beta.len > 0 { format(out, "anthropic-beta: ", p.beta, "\r\n"); }
}

fn ::inference_encode(p: inference::Anthropic, params: inference::Params,
                      conv: inference::Item..[>..]&, out: u8[>..]&) {
    var w = json::writer(out);
    w.object() {
        w.field("model", params.model);
        w.field("max_tokens", params.max_tokens);
        if params.system.len > 0 { w.field("system", params.system); }
        if params.tools.len > 0 {
            w.key("tools");
            w.array() {
                for t in params.tools {
                    w.object() {
                        w.field("name", t.name);
                        if t.description.len > 0 { w.field("description", t.description); }
                        w.key("input_schema");
                        w.raw(if t.schema.len > 0 { t.schema } else { "{\"type\":\"object\"}" });
                    };
                }
            };
        }
        if params.effort.len > 0 {
            w.key("output_config");
            w.object() { w.field("effort", params.effort); };
        }
        if params.cache {
            w.key("cache_control");
            w.object() { w.field("type", "ephemeral"); };
        }
        if params.extra.len > 0 {
            // Written after a member, so the writer's comma is due.
            out.push(',');
            out.append(params.extra);
        }
        w.key("messages");
        w.array() {
            var role = 0;           // of the item's message: 1 user, 2 assistant
            var open = 0;           // of the message being written; 0 for none
            for it in conv {
                match it {
                    User => { role = 1; },
                    Assistant => { role = 2; },
                    _ => {
                        if open != role {
                            if open != 0 { json::close(w, ']'); json::close(w, '}'); }
                            json::open(w, '{');
                            w.field("role", if role == 2 { "assistant" } else { "user" });
                            w.key("content");
                            json::open(w, '[');
                            open = role;
                        }
                        inference::anthropic_block(w, it);
                    },
                }
            }
            if open != 0 { json::close(w, ']'); json::close(w, '}'); }
        };
    };
}

fn anthropic_block(w: json::Writer<u8[>..]>&, it: Item..&) {
    match it {
        Text t => {
            if t.raw.len > 0 { w.raw(t.raw); } else {
                w.object() { w.field("type", "text"); w.field("text", t.text[..]); };
            }
        },
        ToolCall c => {
            if c.raw.len > 0 { w.raw(c.raw); } else {
                w.object() {
                    w.field("type", "tool_use");
                    w.field("id", c.id[..]);
                    w.field("name", c.name[..]);
                    w.key("input");
                    w.raw(if c.input.len > 0 { c.input[..] } else { "{}" });
                };
            }
        },
        ToolResult r => {
            w.object() {
                w.field("type", "tool_result");
                w.field("tool_use_id", r.id[..]);
                w.field("content", r.content[..]);
                if r.is_error { w.key("is_error"); w.boolean(true); }
            };
        },
        Opaque o => { if o.raw.len > 0 { w.raw(o.raw); } },
        User, Assistant => {},
    }
}

fn ::inference_decode(p: inference::Anthropic, body: const u8[:],
                      conv: inference::Item..[>..]&, res: inference::Response&) -> bool {
    let d = json::parse(body);
    guard d.ok() && d.root().is_object() else {
        return inference::fail(res, "malformed", "the reply is not a JSON object");
    }
    let r = d.root();
    guard r.get("type").string() == "message" && r.get("content").is_array() else {
        return inference::fail(res, "malformed", "the reply is not a message");
    }
    inference::clip(res.id, r.get("id").string());
    inference::clip(res.model, r.get("model").string());
    let reason = r.get("stop_reason").string();
    inference::clip(res.stop_reason, reason);
    res.stop = inference::anthropic_stop(reason);
    let u = r.get("usage");
    res.input_tokens = u.get("input_tokens").int();
    res.output_tokens = u.get("output_tokens").int();
    res.cache_read_tokens = u.get("cache_read_input_tokens").int();
    res.cache_write_tokens = u.get("cache_creation_input_tokens").int();

    conv.push(inference::Item.Assistant);
    r.get("content").each() { b =>
        var raw: u8[>..] = [];
        inference::json_text(raw, b);
        let kind = b.get("type").string();
        if kind == "text" {
            conv.push(inference::Item.Text { text: b.get("text").string(), raw: raw[..] });
        } else if kind == "tool_use" {
            var input: u8[>..] = [];
            inference::json_text(input, b.get("input"));
            conv.push(inference::Item.ToolCall { id: b.get("id").string(), name: b.get("name").string(),
                                                 input: input[..], raw: raw[..] });
        } else {
            conv.push(inference::Item.Opaque { kind: kind[..min(kind.len, 40)], raw: raw[..] });
        }
    };
    return true;
}

fn anthropic_stop(reason: const u8[:]) -> i64 {
    if reason == "end_turn" || reason == "stop_sequence" { return STOP_END; }
    if reason == "tool_use" { return STOP_TOOL_USE; }
    if reason == "max_tokens" || reason == "model_context_window_exceeded" { return STOP_MAX_TOKENS; }
    if reason == "pause_turn" { return STOP_PAUSE; }
    if reason == "refusal" { return STOP_REFUSAL; }
    return STOP_OTHER;
}

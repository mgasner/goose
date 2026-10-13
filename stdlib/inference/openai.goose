// OpenAI-compatible Chat Completions: POST /v1/chat/completions. OpenAI
// itself, and the local servers that copy its API (vLLM, llama.cpp,
// Ollama, ...).

namespace inference;

import std;
import json;

struct OpenAI {
    // The request's token limit: OpenAI's current name, or "max_tokens",
    // which most other servers take.
    tokens_field: u8[..32] = "max_completion_tokens",
}

fn openai(api_key: const u8[:], base_url: const u8[:] = "https://api.openai.com") -> Client<OpenAI> {
    Client<OpenAI> { provider: OpenAI { .. }, base_url: base_url, api_key: api_key, .. }
}

fn ::inference_path(p: inference::OpenAI) -> const u8[:] { "/v1/chat/completions" }

fn ::inference_headers(p: inference::OpenAI, api_key: const u8[:], out: u8[>..]&) {
    if api_key.len > 0 { format(out, "Authorization: Bearer ", api_key, "\r\n"); }
}

// A user turn becomes a "tool" message per tool result, then one user
// message of its text; an assistant turn, one message with its text and
// tool calls. Raw and opaque blocks are another provider's, and left out.
fn ::inference_encode(p: inference::OpenAI, params: inference::Params,
                      conv: inference::Item..[>..]&, out: u8[>..]&) {
    var w = json::writer(out);
    w.object() {
        w.field("model", params.model);
        w.field(p.tokens_field[..], params.max_tokens);
        if params.tools.len > 0 {
            w.key("tools");
            w.array() {
                for t in params.tools {
                    w.object() {
                        w.field("type", "function");
                        w.key("function");
                        w.object() {
                            w.field("name", t.name);
                            if t.description.len > 0 { w.field("description", t.description); }
                            w.key("parameters");
                            w.raw(if t.schema.len > 0 { t.schema } else { "{\"type\":\"object\"}" });
                        };
                    };
                }
            };
        }
        if params.effort.len > 0 { w.field("reasoning_effort", params.effort); }
        if params.extra.len > 0 {
            out.push(',');
            out.append(params.extra);
        }
        w.key("messages");
        w.array() {
            if params.system.len > 0 {
                w.object() { w.field("role", "system"); w.field("content", params.system); };
            }
            // A message's text and tool calls, gathered until it ends.
            var text: u8[>..] = [];
            var calls: u8[>..] = [];
            var role = 0;
            var open = 0;
            var has_text = false;
            fn flush() {
                if open == 1 && has_text {
                    w.object() { w.field("role", "user"); w.field("content", text[..]); };
                } else if open == 2 && (has_text || calls.len > 0) {
                    w.object() {
                        w.field("role", "assistant");
                        w.key("content");
                        if has_text { w.string(text[..]); } else { w.none(); }
                        if calls.len > 0 {
                            w.key("tool_calls");
                            w.raw(str("[", calls, "]"));
                        }
                    };
                }
                text.clear();
                calls.clear();
                has_text = false;
            }
            for it in conv {
                match it {
                    User => { role = 1; },
                    Assistant => { role = 2; },
                    _ => {
                        if open != role {
                            flush();
                            open = role;
                        }
                        match it {
                            Text t => {
                                text.append(t.text);
                                has_text = true;
                            },
                            ToolCall c => {
                                if calls.len > 0 { calls.push(','); }
                                var cw = json::writer(calls);
                                cw.object() {
                                    cw.field("id", c.id[..]);
                                    cw.field("type", "function");
                                    cw.key("function");
                                    cw.object() {
                                        cw.field("name", c.name[..]);
                                        cw.field("arguments", if c.input.len > 0 { c.input[..] } else { "{}" });
                                    };
                                };
                            },
                            ToolResult r => {
                                w.object() {
                                    w.field("role", "tool");
                                    w.field("tool_call_id", r.id[..]);
                                    w.field("content", r.content[..]);
                                };
                            },
                            _ => {},
                        }
                    },
                }
            }
            flush();
        };
    };
}

fn ::inference_decode(p: inference::OpenAI, body: const u8[:],
                      conv: inference::Item..[>..]&, res: inference::Response&) -> bool {
    let d = json::parse(body);
    guard d.ok() && d.root().is_object() else {
        return inference::fail(res, "malformed", "the reply is not a JSON object");
    }
    let r = d.root();
    let choice = r.get("choices").at(0);
    let m = choice.get("message");
    guard m.is_object() else { return inference::fail(res, "malformed", "the reply has no message"); }
    inference::clip(res.id, r.get("id").string());
    inference::clip(res.model, r.get("model").string());
    let reason = choice.get("finish_reason").string();
    inference::clip(res.stop_reason, reason);
    res.stop = inference::openai_stop(reason);
    let u = r.get("usage");
    res.input_tokens = u.get("prompt_tokens").int();
    res.output_tokens = u.get("completion_tokens").int();
    res.cache_read_tokens = u.get("prompt_tokens_details").get("cached_tokens").int();

    conv.push(inference::Item.Assistant);
    let text = m.get("content").string();
    if text.len > 0 { conv.push(inference::Item.Text { text: text, raw: "" }); }
    let refusal = m.get("refusal").string();
    if refusal.len > 0 {
        conv.push(inference::Item.Text { text: refusal, raw: "" });
        res.stop = inference::STOP_REFUSAL;
    }
    m.get("tool_calls").each() { c =>
        let f = c.get("function");
        conv.push(inference::Item.ToolCall { id: c.get("id").string(), name: f.get("name").string(),
                                             input: f.get("arguments").string(), raw: "" });
    };
    return true;
}

fn openai_stop(reason: const u8[:]) -> i64 {
    if reason == "stop" { return STOP_END; }
    if reason == "tool_calls" || reason == "function_call" { return STOP_TOOL_USE; }
    if reason == "length" { return STOP_MAX_TOKENS; }
    if reason == "content_filter" { return STOP_REFUSAL; }
    return STOP_OTHER;
}

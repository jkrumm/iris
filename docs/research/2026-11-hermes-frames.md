# What a Hermes turn really sends (Issue 642)

Recorded 2026-11-10 against the production Hermes gateway (hermes-agent `b200f5bc60`, `gateway/platforms/api_server.py`, `_handle_session_chat_stream`), with the same
`POST /api/sessions/<id>/chat/stream` call and `system_message` Iris sends. Streaming and artifacts are built on this note.

## Verdict

| Question | Answer |
|-|-|
| Text deltas (`assistant.delta`) | **Yes**, but not live. All 28 deltas of the probe turn arrived within one millisecond at +7.02 s, after the last tool finished (+4.41 s) and 0.07 s before `assistant.completed`. The `ts` is stamped when Hermes enqueues the frame, so the burst is real, not a network effect. The production turn had 36 deltas (timing not logged). Nothing in the stream shows tokens arriving as they are generated. |
| Delta text equals the final text | Almost: the joined deltas carry a leading `\n\n` (327 vs 325 chars) that `assistant.completed.content` has stripped. The deltas contain the whole ```` ```iris ```` block, so a client that shows deltas must hold the fence back. |
| Text between tool calls | **Probe turn: none** (the assistant messages around the tool calls have empty `content`, no delta before the last model call). The production turn's session store has one 103-char interim assistant message between its two `terminal` calls; no `assistant.commentary` frame was sent for it, whether it also came as deltas is not known (only counts were logged). |
| Partial `assistant.completed` before the final one | **No.** Exactly one per turn, `partial: false`, `interrupted: false`, `completed: true`. |
| Tool results | **Not in the tool frames, yes in `run.completed.messages`.** `tool.started` carries `tool_name`, a `preview` string and `args`; `tool.completed` has `preview: null` and `args: null`. The result text is only in the `role: "tool"` entries of `run.completed.messages[]` (`content` string, `tool_call_id`, `tool_name`): 10 213 chars for the `skill_view` of `iris`, 523 for the `terminal` call. |
| Tool failure | `tool.failed` exists and fires when a tool result is an error (production turn: Hermes logged one `terminal` call as "returned error" and sent `tool.failed`, so 3 `tool.started` met 2 `tool.completed` + 1 `tool.failed`; `tool.failed` has the same keys as `tool.completed`). Iris reads only `tool.started`, so a failed call is still in `actions`. |
| Attachments / file references | **No.** No key or event named attachment, file, media or image in either turn. By the source, a `MEDIA:<path>` tag for an image in the *final* reply is replaced by an inline `![image](data:…;base64,…)` in `assistant.completed.content` (`_resolve_media_to_data_urls`, size capped); non-image paths stay as text. Deltas are not rewritten. Not observed, no turn produced an image. |

## Frame table

Run `run_be0b7009c1d047aab3d312554940a28b` (session `d3faa912-b988-4498-b31f-bfb5e258e879`, raw `curl`-equivalent client, prompt: list the three newest files in this
folder with the terminal, as a table). Offsets are the frames' own `ts`, from the first frame. Frames of the same turn through Iris (memo
`ad6a8cf3-6137-4d71-b1b8-be2f749f4ef6`, trace `ad6a8cf361374d71b1b8be2f749f4ef6`) were logged by the new `hermes.frames` line with the identical key sets.

Every frame also carries the envelope `session_id`, `run_id`, `seq` (1, 2, 3 … contiguous, no gaps) and `ts` (float seconds). Order of the run:

`run.started` > `message.started` > `tool.started` > `tool.completed` > `tool.started` > `tool.completed` > `assistant.delta` ×28 > `assistant.completed` > `run.completed` > `done`

| Event | At | Keys beyond the envelope |
|-|-|-|
| `run.started` | +0.00 s | `user_message{role, content}`, `runtime` |
| `message.started` | +0.00 s | `message{id, role}` |
| `tool.started` | +2.01, +4.17 s | `message_id`, `tool_name`, `preview` (string), `args` (object: `skill_view` `{name}`, `terminal` `{command, timeout}`) |
| `tool.completed` | +2.08, +4.41 s | `message_id`, `tool_name`, `preview` (null), `args` (null) |
| `tool.failed` | (production turn only) | same keys as `tool.completed` |
| `assistant.delta` | +7.02 s, 28 frames in 1 ms | `message_id`, `delta` (3 to 22 chars each) |
| `assistant.completed` | +7.09 s | `message_id`, `content`, `completed`, `partial`, `interrupted`, `runtime{provider, model, route_source, requested}` |
| `run.completed` | +7.09 s | `message_id`, `completed`, `partial`, `interrupted`, `messages[]`, `usage{input_tokens, output_tokens, total_tokens}`, `runtime` |
| `done` | +7.09 s | none |

`run.completed.messages[]` is the authoritative per-turn transcript (the source's own words: clients accumulating deltas cannot rebuild segments before tool calls). Here five entries:
`assistant` (empty content, `tool_calls[]` of `{id, call_id, response_item_id, type, function}`), `tool`, `assistant`, `tool`, `assistant` (the reply). Keys of an assistant entry: `role`, `content`,
`tool_calls`, `timestamp`, `finish_reason`, `reasoning`, `reasoning_content`; of a tool entry: `role`, `content`, `tool_call_id`, `tool_name`, `timestamp`.

Not seen in these turns, present in the source: `tool.progress` (`{message_id, tool_name, delta}`, from reasoning), `assistant.commentary` (`{message_id, text, already_streamed}`, mid-turn text beside tool calls on some
providers), `approval.request`, `run.failed` / `run.cancelled` in place of `run.completed` (same keys plus `turn_exit_reason`), `run.queued` when a live Bot Chat holds the session, and
`error {message}` before `done`. Keepalives are SSE comments (`: keepalive`), not events. `done` always closes the stream.

## What this means for the work built on it

- **Streaming the reply to the app is not a progress stream today.** With this provider the text lands in one burst after the last model call; what is live is the tool phase (`tool.started` / `tool.completed`, 2 to 4 s apart here). Show tool progress, not typing, and do not promise token streaming.
- **Cut the fence from any delta text.** The ```` ```iris ```` block is inside the deltas; the final `content` is what `parseIrisBlock` already handles.
- **Artifacts from tool output** have to come from `run.completed.messages[].content` (strings, so a tool that returns JSON returns a JSON string), not from `tool.completed`.
- Files or images: nothing structured. The only carrier is the reply text (`MEDIA:` resolved to a data URL in `content`).

## What the iris skill tells Hermes about the reply

`skills/iris/SKILL.md` (hermes-agent): the message is a speech-to-text transcript; the reply is "what he reads on a phone: verdict first, short, usually 1 to 4 lines"; markdown renders ("lists, code, tables, Mermaid; use it only when it carries content");
no greeting, no process narration; name what happened and where (issue link, list, note path); no secrets, tokens or hostnames; the reply and `headline` are in the memo's language. It asks nothing. It says nothing about streaming, attachments, files, images or
tool-result display. The reply ends with exactly one ```` ```iris ```` block, one line of JSON with the keys `kind` (1 to 3 words) and `headline` (≤ 60 characters), nothing after the closing fence, always present, also on failure. The probe turn followed this: a table, then the block.

## Method

- Server: Iris `hermes.frames` debug line (`server/src/adapters/hermes.ts`): per turn, event names with counts and the union of top-level key names per event, never values; test `logs hermes.frames with event counts and key names, never values`.
- Real turn through production after the deploy: typed memo via `scripts/send-memo.ts --text` with the smoke device. Hermes `run_id` is a value and is not logged, so the run named above comes from a second, identical turn sent straight to the gateway, whose full SSE body was read (offsets, nested key names, delta joins). Both turns used the terminal tool and answered with a table; the key sets match.
- Limits: two turns, one provider, one prompt. Cadence of deltas on a provider that streams natively, and the `tool.failed` / `assistant.commentary` / `tool.progress` shapes, are from the source and the production counts, not from a recorded frame.

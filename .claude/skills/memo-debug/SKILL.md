---
name: memo-debug
description: Debug one Iris memo end to end — fetch it from iris-server, read the step timeline, find the HyperDX trace, retry a failed step. Use when a memo is stuck at transcribed, failed(act), has a wrong kind or missing actions, or a user reports a wrong or missing result.
---

# memo-debug

Input: a memo id (UUID; the trace id is the same UUID with the dashes stripped). Production is the loopback instance on the mini
(`127.0.0.1:7730`, also `https://iris.mini.<domain>`). Never `op` on the mini: tokens come from `secrets-run`.

```bash
T=$(secrets-run read op://mini/iris/device-tokens | tr ',' '\n' | awk -F= '$2=="smoke"{print $1}')   # ran; never print $T
H="Authorization: Bearer $T"; B=http://127.0.0.1:7730
curl -s $B/health                                                   # {"status","degraded":[],"inflight","receiving"}  (ran)
curl -s -H "$H" "$B/v1/memos?limit=5" | jq '.items[]|{id,state,kind}'        # ran: newest first
curl -s -H "$H" $B/v1/memos/$ID | jq '{state,failedStep,error,kind,actions,steps:[.steps[]|{step,status,error,costUsd}]}'   # ran
curl -s -H "$H" "$B/v1/memos/$ID/result?wait=0"                     # 200 once result-ready, 202 otherwise
```

Reading it: `state` is the last finished step; `failedStep` + `error` say what broke; `transcribed` for long means `act` has no handler (Hermes unconfigured: `/health` `degraded` lists `act`) or the runner is down; `failed` + `failedStep: act` is a Hermes error (the `error` text says which). `kind` and `actions` are what Hermes reported (`kind` null
means no valid ```iris block: look for the `hermes.meta_invalid {memo_id, reason}` log line in the trace; `reason` is `missing_block`, `invalid_json` or `invalid_shape: <paths>`). A `notified` memo with `summary` null and a failed `summarize` step is a skipped triage (agw down, a 402): retry from `summarize`. A memo from before Wave 21 S1 may sit in `needs_route` or `routed`; migration 14 turned the open ones into `failed(act)`. A memo stuck in `receiving` means the upload never completed (compare `segmentCount` with what the device sent).

## The trace

HyperDX, `service.name = iris-server`, trace id = `<memo id without dashes>`: root span `memo`, one child per step (`transcribe`,
`act`, `summarize`, `notify`), correlated logs on the same trace id. Query it through the `/otel` skill (prod), e.g. "all spans and logs of
trace `<id without dashes>`". The shape was verified in Wave 4 (13 OK spans + 3 logs for a smoke memo); it was not re-queried this wave.
Local server logs: `make logs` (bounded tail of `~/Library/Logs/iris*.log`).

### Timing, tokens, cost and requests (since Issue 2518)

On the same trace (`service.name = iris-server`):

| Span | Attributes |
|-|-|
| `hermes.chat_stream` | `headers_ms`, `first_frame_ms`, `first_token_ms` (ms from the request sent; a stall before the first token shows here), `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `api_calls`, `model`, `cost_usd`, `cost_estimated` |
| `act`, `transcribe`, `summarize` | `cost_usd` and `cost_estimated` (true = price table, false = the downstream's own); the step row's `usage.costEstimated` says the same |
| `audio_door.transcribe` | `cost_usd`, `cost_estimated`, `agw.run_id` |

Cache tokens and `api_calls` come from the session's counters (`GET /api/sessions/{id}` before and after the turn): absent when that read failed. A `hermes.cost_unpriced` log line (`model`) means the model has no rate in `memo/pricing.ts`. Request load is not on the memo trace: one root span per request, `<METHOD> <route template>` (`GET /v1/memos/:id`, `unmatched` for no route) with `http.route`, `http.response.status_code` (a 5xx is an error span), and for `GET /v1/events` the `sse.opened` log (`open_streams`, `reconnect`) and the `sse.stream` span (lifetime, `close_reason`). Via `/otel`, prod: "spans of `iris-server` named `hermes.chat_stream` or `transcribe` or `act` for trace `<id>` with their attributes"; "count of iris-server spans by `http.route` and `http.response.status_code` over the last hour"; "`sse.opened` logs, latest `open_streams`".

## The device side of the timeline (unverified until a device take)

A memo recorded on the phone has a second half of the story under the same trace id: `service.name = iris-ios` records (`take.phase`, `capture.*`,
`audio.*`, `outbox.*`, `intent.*`, `liveactivity.*`, `metrickit.*`; TDD §8). Query the trace id (the memo id without dashes) without a service filter to see
device and server together, ordered by `seq` for the phone's rows (`uptime_ms` for durations) and by timestamp for the server's:

- the phone says the take ended (`take.phase` `stopped`, `outbox.complete.sent` `status=ok`) and the memo is stuck in `receiving`: compare its `segment_count`
  with `segmentCount` here, and look for a `capture.segment.closed` index that has no `outbox.segment.upload` (the file is in `capture/quarantine/` or still queued);
- no `iris-ios` rows at all: the take never started (see `intent.perform`) or the phone could not reach the server and the records wait in its crash file for the next launch.

Full recipe, the `run.id` filter and what each record means: skill `device`, "One take's device timeline".

## Retry

`POST /v1/memos/$ID/retry {"from":"<step>"}` re-drives from that step and clears the columns of it and later steps; 409 unless the memo is
`failed`; 400 for a step outside the memo's pipeline (a typed memo has no `transcribe`, mode `transcribe` has no `act`). A stuck or failed Hermes turn retries from `act`; an old `failed(route)` also from `act`; a `notified` memo whose `summarize` failed, or is `done` with no summary (late work a restart cut), retries from `summarize` (and re-sends the push). **Unverified live** (covered by server tests only); do it on a real failed memo, not a healthy one. `act` is at-least-once: a retry
of `act` posts a second turn into the same Hermes session. A downstream that was down turns the memo `failed`; check `/health` `degraded`
first (`act` there means Hermes is not configured: the memo waits at `transcribed`, no retry needed once it is), then retry.

Smoke a healthy path with `make smoke` (a real German recording through the production door).

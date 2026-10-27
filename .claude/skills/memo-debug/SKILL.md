---
name: memo-debug
description: Debug one Iris memo end to end — fetch it from iris-server, read the step timeline, find the HyperDX trace, retry a failed step. Use when a memo is stuck, failed, parked at needs_route, or a user reports a wrong or missing result.
---

# memo-debug

Input: a memo id (UUID; the trace id is the same UUID with the dashes stripped). Production is the loopback instance on the mini
(`127.0.0.1:7730`, also `https://iris.mini.<domain>`). Never `op` on the mini: tokens come from `secrets-run`.

```bash
T=$(secrets-run read op://mini/iris/device-tokens | tr ',' '\n' | awk -F= '$2=="smoke"{print $1}')   # ran; never print $T
H="Authorization: Bearer $T"; B=http://127.0.0.1:7730
curl -s $B/health                                                   # {"status","degraded":[],"inflight"}  (ran)
curl -s -H "$H" "$B/v1/memos?limit=5" | jq '.items[]|{id,state,route}'        # ran: newest first
curl -s -H "$H" $B/v1/memos/$ID | jq '{state,failedStep,error,route,steps:[.steps[]|{step,status,error,costUsd}]}'   # ran
curl -s -H "$H" "$B/v1/memos/$ID/result?wait=0"                     # 200 once result-ready, 202 otherwise
```

Reading it: `state` is the last finished step; `failedStep` + `error` say what broke; `needs_route` is parked on purpose (waiting for a
choice, Phase 2). A memo stuck in `receiving` means the upload never completed (compare `segmentCount` with what the device sent).

## The trace

HyperDX, `service.name = iris-server`, trace id = `<memo id without dashes>`: root span `memo`, one child per step (`transcribe`, `route`,
`act`, `summarize`, `notify`), correlated logs on the same trace id. Query it through the `/otel` skill (prod), e.g. "all spans and logs of
trace `<id without dashes>`". The shape was verified in Wave 4 (13 OK spans + 3 logs for a smoke memo); it was not re-queried this wave.
Local server logs: `make logs` (bounded tail of `~/Library/Logs/iris*.log`).

## Retry

`POST /v1/memos/$ID/retry {"from":"<step>"}` re-drives from that step and clears the columns of it and later steps; 409 unless the memo is
`failed`. **Unverified live** (covered by server tests only); do it on a real failed memo, not a healthy one. `act` is at-least-once: a retry
of `act` posts a second turn into the same Hermes session. A downstream that was down turns the memo `failed`; check `/health` `degraded`
first, then retry.

Smoke a healthy path with `make smoke` (a real German recording through the production door).

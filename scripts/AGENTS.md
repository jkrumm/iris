# scripts/ (drivers, deploy poller, release hooks, device and Apple wrappers)

Tests sit next to the scripts and run with `bun test scripts`. Deploy, release hooks, versions, Mac releases, TestFlight crash intake and the downstream env: `docs/release-and-ops.md`; read it before changing `mini-deploy.sh`, `release-hooks.sh`, `mac-release.sh`, `testflight*.{sh,ts}` or the plists in `launchd/`. Device build and signing: `docs/device.md` and skill `device`. CI jobs, the uitest subset and simulator memory: `docs/validate.md`.

## Apple wrappers

- Every heavy Apple target runs through `scripts/apple-slot`: on the mini it is `lockf /tmp/iris-apple.lock` around `factory slot run --name iris-apple`, so one Apple job runs at a time. Exit 75 means no slot or lock within the wait; retry later. Never type `lockf` by hand, and never nest a slot: a target called by another runs bare inside its parent's slot (`IRIS_APPLE_SLOT`).
- `make uitest` without `ONLY=` refuses outside CI, because the full suite is CI's; `IRIS_FULL_UITEST=1` overrides it only on the owner's explicit request. Never rerun a full suite to bisect: read the CI log and run the failing test alone.
- A stock simulator peaks near 19 GiB and drove the mini into swap. `scripts/sim-slim` disables the services tests never use; keep the simulator's processes under 7.5 GiB RSS (`make sim-slim SIM_MEASURE=1` measures). Disabling Accessibility, notifications, Live Activities, location, pasteboard, LaunchServices, the extension stack, `nanoregistryd` or the store stack hangs the boot or the install. Never run parallel simulator clones; shut simulators down (`make sim-down`).

## Deploy and runtime

- Push to master deploys: `com.jkrumm.iris-deploy` runs `scripts/mini-deploy.sh` every 120 s and deploys only when `check` is green on that sha and no memo is mid-step (`/health` `inflight` is 0). The server runs from the deploy clone `~/.iris/app`, never from a checkout; data lives in `~/.iris/data`.
- A tick restarts only for runtime paths (docs, tests, the Makefile and `launchd/` do not). A changed `launchd/` template needs `make launchd-install` on the mini.
- `scripts/launch.sh` refuses to start with `IRIS_FAKES` set or a base secret ref that does not resolve; a missing OTel overlay starts degraded. Secrets come from `.env.local.tpl` and `.env.mini.tpl` through `secrets-run`; never `op`.
- Release hooks (`testflight`, `mac`) are off unless the untracked `~/.iris/release.env` enables them, start only through the gate (marker at least 12 h old, Apple lock free, factory slot free) and never from a single commit. `DRY_RUN=1 scripts/release-hooks.sh <sha>` prints what would start and changes nothing. A hook's marker is written only after its make target succeeded.
- Both apps get `0.MINOR.PATCH` from `bun scripts/version.ts` (git only, deterministic per commit; a shallow clone fails loud). `make testflight` and `make mac-release` take `DRY_RUN=1` to print version, build and notes without signing.
- `sign_update` and `generate_appcast` read the Sparkle key from `--ed-key-file`, never the keychain, because run headless they hang on the keychain prompt. Only Mac releases may be published on this repo: `releases/latest` is the Sparkle feed, and a draft is never latest.
- A job started by a LaunchAgent has no `/usr/sbin` on its PATH; call `/usr/sbin/spctl` and the like by full path.
- The TestFlight crash intake files one factory Issue per crash group (`factory issue new --key testflight-crash-<oldest submission id>`, so a re-run is a no-op); raw logs are written 0600 under `.artifacts/` and the tester's email and device facts are never copied. `make testflight-crashes ARGS=--dry-run` prints the command and files nothing.

## Device scripts

- `scripts/device-build.sh` reads the App Store Connect key with `secrets-run read` from `op://mini/apple-developer`, never `op`. `pem_normalize` (`scripts/apple-signing-key.sh`) rebuilds the `.p8` newlines into a 0600 temp file that a `trap` deletes on every exit; the key is in no argv, log or tracked file.
- Never rename the three bundle ids (`com.jkrumm.iris`, `.widgets`, `.notifications`): a Personal Team allows 10 App IDs per 7 days. The App Group (`group.com.jkrumm.iris`) is an owner portal step; the key cannot create it. The phone must be unlocked for `launch`, and the owner trusts the developer on it once after the first install.
- The phone resolves at runtime (`devicectl list devices`); nothing about it is tracked. Screenshot with `xcrun devicectl device capture screenshot`: `pymobiledevice3` does not work against the CoreDevice tunnel.

## Drivers

- `bun scripts/send-memo.ts <audio-file>` splits the file into 10 s m4a segments with ffmpeg and runs a memo like the phone does. Env `IRIS_URL` (default `http://127.0.0.1:7730`) and `IRIS_TOKEN` (required); flags `--mode`, `--wait`, `--thread`. Exit 0 `notified`, 1 `failed`, 2 timeout or usage error.
- `make e2e` (`scripts/e2e.ts`) boots the server on a free port with `IRIS_FAKES=1` and a temp `IRIS_DATA`, drives the smoke recording and probes the routes; every memo must reach `notified`.
- `make smoke` sends the real German recording through production (`IRIS_URL=https://iris.mini.<domain> make smoke` for the tailnet door).

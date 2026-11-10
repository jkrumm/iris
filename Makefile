.DEFAULT_GOAL := help

# Mini LaunchAgents: iris-server (:7730) and its deploy poller run from the DEDICATED deploy clone
# ~/.iris/app, never this dev checkout (see scripts/mini-deploy.sh, scripts/launch.sh).
APP_DIR      := $(HOME)/.iris/app
DATA_DIR     := $(HOME)/.iris/data
LAUNCHD_DIR  := $(APP_DIR)/launchd
LAUNCHAGENTS := $(HOME)/Library/LaunchAgents
REPO_URL     := https://github.com/jkrumm/iris.git
LABEL        := com.jkrumm.iris
LABEL_DEPLOY := com.jkrumm.iris-deploy
LABEL_CRASHES := com.jkrumm.iris-testflight-crashes
HEALTH_URL   := http://127.0.0.1:7730/health
AUDIO_DOOR_HEALTH_URL := http://127.0.0.1:7792/health
AGW_HEALTH_URL := http://127.0.0.1:7791/health
LINES        ?= 100

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-14s %s\n", $$1, $$2}'

# check-apple needs Xcode; it joins `check` only where xcodebuild exists (the Linux CI job has none, apple.yml runs it).
CHECK_APPLE := $(if $(shell command -v xcodebuild 2>/dev/null),check-apple)

.PHONY: check
check: check-server check-contracts check-strings guard $(CHECK_APPLE) ## Everything CI runs except e2e (check-apple joins where Xcode exists)

.PHONY: check-server
check-server: ## oxlint, oxfmt --check, tsc --noEmit, bun test (server and scripts)
	cd server && bun install --frozen-lockfile
	cd server && bun run lint
	cd server && bun run format:check
	cd server && bun run typecheck
	cd server && bun run test
	bun test scripts

.PHONY: check-strings
check-strings: ## String catalogs: every key translated to de, none stale, no hard-coded user-facing literal (needs only bun)
	bun test scripts/check-strings.test.ts
	bun scripts/check-strings.ts

.PHONY: check-contracts
check-contracts: ## contracts/schema equals the TypeBox export, fixtures validate, manifest covers every route
	cd server && bun install --frozen-lockfile
	cd server && bun run contracts:check

.PHONY: contracts
contracts: ## Regenerate contracts/schema from the TypeBox schemas
	cd server && bun run contracts:export

.PHONY: format
format: ## Apply oxfmt
	cd server && bun run format

.PHONY: merge-guard
merge-guard: ## Before merging a PR: rebased on origin/master, master's last check.yml run green (MERGE_GUARD_ARGS=--allow-red only to fix a red master)
	@bun scripts/merge-guard.ts $(MERGE_GUARD_ARGS)

.PHONY: guard
guard: ## Public-repo guard: no IPs, tailnet/real hostnames or token shapes in tracked files
	bun scripts/public-guard.ts

.PHONY: mockups
mockups: ## Regenerate docs/design tokens.css and render every mockup to docs/design/renders/ (headless Chrome)
	bun docs/design/mockups/gen-tokens.ts
	bun docs/design/render.ts

.PHONY: mini-setup
mini-setup: ## Clone/update the deploy clone, install deps, install the LaunchAgents
	@mkdir -p "$(DATA_DIR)"
	@if [ -d "$(APP_DIR)/.git" ]; then \
	  echo "  updating existing clone at $(APP_DIR)"; \
	  git -C "$(APP_DIR)" fetch origin master && git -C "$(APP_DIR)" reset --hard origin/master; \
	else \
	  echo "  cloning $(REPO_URL) -> $(APP_DIR)"; \
	  git clone --branch master "$(REPO_URL)" "$(APP_DIR)"; \
	fi
	cd "$(APP_DIR)/server" && bun install --frozen-lockfile --production
	@chmod +x "$(APP_DIR)"/scripts/*.sh
	$(MAKE) -C "$(APP_DIR)" launchd-install
	@# What setup just started IS the deployed build; without the marker the poller's first tick
	@# would diff from the empty tree and restart a freshly started service for nothing.
	@git -C "$(APP_DIR)" rev-parse HEAD > "$(HOME)/.iris/deployed-sha"

.PHONY: launchd-install
launchd-install: ## Render the plist templates (__HOME__ substituted) and (re)load the three LaunchAgents
	@mkdir -p "$(LAUNCHAGENTS)" "$(HOME)/Library/Logs"
	@sed "s|__HOME__|$(HOME)|g" "$(LAUNCHD_DIR)/$(LABEL).plist.template" > "$(LAUNCHAGENTS)/$(LABEL).plist"
	@sed "s|__HOME__|$(HOME)|g" "$(LAUNCHD_DIR)/$(LABEL_DEPLOY).plist.template" > "$(LAUNCHAGENTS)/$(LABEL_DEPLOY).plist"
	@sed "s|__HOME__|$(HOME)|g" "$(LAUNCHD_DIR)/$(LABEL_CRASHES).plist.template" > "$(LAUNCHAGENTS)/$(LABEL_CRASHES).plist"
	@launchctl bootout "gui/$$(id -u)/$(LABEL)" 2>/dev/null || true
	@launchctl bootstrap "gui/$$(id -u)" "$(LAUNCHAGENTS)/$(LABEL).plist"
	@launchctl bootout "gui/$$(id -u)/$(LABEL_DEPLOY)" 2>/dev/null || true
	@launchctl bootstrap "gui/$$(id -u)" "$(LAUNCHAGENTS)/$(LABEL_DEPLOY).plist"
	@launchctl bootout "gui/$$(id -u)/$(LABEL_CRASHES)" 2>/dev/null || true
	@launchctl bootstrap "gui/$$(id -u)" "$(LAUNCHAGENTS)/$(LABEL_CRASHES).plist"
	@rm -f "$(HOME)/.iris/launchd-pending"
	@echo "installed $(LABEL), $(LABEL_DEPLOY), $(LABEL_CRASHES)"

.PHONY: launchd-uninstall
launchd-uninstall: ## Unload and remove the three LaunchAgents
	@launchctl bootout "gui/$$(id -u)/$(LABEL_CRASHES)" 2>/dev/null || true
	@launchctl bootout "gui/$$(id -u)/$(LABEL_DEPLOY)" 2>/dev/null || true
	@launchctl bootout "gui/$$(id -u)/$(LABEL)" 2>/dev/null || true
	@rm -f "$(HOME)/.local/state/jobs/$(LABEL_DEPLOY).json" "$(HOME)/.local/state/jobs/$(LABEL_CRASHES).json"
	@rm -f "$(LAUNCHAGENTS)/$(LABEL_DEPLOY).plist" "$(LAUNCHAGENTS)/$(LABEL).plist" "$(LAUNCHAGENTS)/$(LABEL_CRASHES).plist"
	@echo "removed $(LABEL), $(LABEL_DEPLOY), $(LABEL_CRASHES)"

.PHONY: launchd-status
launchd-status: ## launchctl state for the LaunchAgents + curl /health
	@launchctl print "gui/$$(id -u)/$(LABEL)" 2>&1 | head -n 30
	@echo ""
	@launchctl print "gui/$$(id -u)/$(LABEL_DEPLOY)" 2>&1 | head -n 20
	@echo ""
	@launchctl print "gui/$$(id -u)/$(LABEL_CRASHES)" 2>&1 | head -n 20
	@echo ""
	@curl -s $(HEALTH_URL) || echo "$(HEALTH_URL) unreachable"
	@echo ""

.PHONY: launchd-restart
launchd-restart: ## Kickstart (restart) the server; refuses while a memo is mid-step unless FORCE=1
	@if [ -z "$(FORCE)" ]; then \
	  n=$$(curl -sf --max-time 3 $(HEALTH_URL) 2>/dev/null | jq -r '.inflight // 0' 2>/dev/null || echo 0); \
	  if [ "$${n:-0}" != "0" ]; then echo "refusing to restart: $$n memo(s) in flight; FORCE=1 make launchd-restart to restart anyway"; exit 1; fi; \
	fi
	@d="$$HOME/.local/state/devhost/deliberate-restart"; mkdir -p "$$d" && date +%s >> "$$d/$(LABEL)" || true
	@launchctl kickstart -k "gui/$$(id -u)/$(LABEL)"
	@echo "restarted $(LABEL)"

.PHONY: launchd-logs
launchd-logs: ## Tail the iris LaunchAgent logs on this machine
	@tail -n 100 -f "$(HOME)/Library/Logs/iris.log" "$(HOME)/Library/Logs/iris.err" "$(HOME)/Library/Logs/iris-deploy.log" "$(HOME)/Library/Logs/iris-testflight-crashes.log"

.PHONY: testflight-crashes
testflight-crashes: ## Read TestFlight crash reports now and file an Issue per new one (the hourly job's run; ARGS="--dry-run" prints only)
	@"$(HOME)/.local/bin/jobrun" $(LABEL_CRASHES) --owner iris --every 3600 --timeout 600 -- bun "$(APP_DIR)/scripts/testflight-crashes.ts" $(ARGS)

.PHONY: testflight-crashes-baseline
testflight-crashes-baseline: ## Mark every TestFlight crash report that exists now as seen, filing none (once, before the first hourly run)
	@bun "$(APP_DIR)/scripts/testflight-crashes.ts" --baseline

# Repo contract (dotfiles/docs/agent-platform.md): `check` above; deploy, probe, read logs.

.PHONY: deploy
deploy: ## Run the app clone's mini-deploy.sh once, now (the poller's tick: same jobrun lock, same record)
	@"$(HOME)/.local/bin/jobrun" $(LABEL_DEPLOY) --owner iris --every 120 --timeout 1800 --lock iris-deploy -- "$(APP_DIR)/scripts/mini-deploy.sh"

.PHONY: verify
verify: ## Probe production: exit 0 iff /health answers ok and no launchd change is pending
	@if [ -f "$(HOME)/.iris/launchd-pending" ]; then echo "  launchd/ templates changed since the last install: run make launchd-install on the mini"; exit 1; fi
	@curl -fsS --max-time 5 $(HEALTH_URL) | grep -q '"status":"ok"' \
		|| { echo "  iris not healthy ($(HEALTH_URL))"; exit 1; }
	@echo "  iris healthy ($(HEALTH_URL))"
	@curl -fsS --max-time 5 $(AUDIO_DOOR_HEALTH_URL) | grep -Eq '"status" *: *"ok"' \
		|| { echo "  audio door not healthy ($(AUDIO_DOOR_HEALTH_URL))"; exit 1; }
	@echo "  audio door healthy ($(AUDIO_DOOR_HEALTH_URL))"
	@curl -fsS --max-time 5 $(AGW_HEALTH_URL) | grep -Eq '"status" *: *"ok"' \
		|| { echo "  agent-workflows host not healthy ($(AGW_HEALTH_URL))"; exit 1; }
	@echo "  agent-workflows host healthy ($(AGW_HEALTH_URL))"

.PHONY: version
version: ## Print the deployed commit sha (one line, read-only; what the factory checks a shipped commit against)
	@cat "$(HOME)/.iris/deployed-sha" 2>/dev/null || { echo "unknown (no deploy recorded: make deploy)" >&2; exit 1; }

.PHONY: logs
logs: ## Bounded tail (last $(LINES) lines) of the production logs, then exits (no -f)
	@tail -n $(LINES) "$(HOME)/Library/Logs/iris.log" "$(HOME)/Library/Logs/iris.err" "$(HOME)/Library/Logs/iris-deploy.log"

.PHONY: smoke
smoke: ## Send a real German recording end to end (IRIS_URL=https://iris.mini.<domain> AUDIO=<file>); needs the mini
	@./scripts/smoke.sh

.PHONY: e2e
e2e: ## Pipeline end to end against a fake-booted server
	bun scripts/e2e.ts

# --- Apple (apple/project.yml, apple/Packages/*); toolchain recipes: .claude/skills/apple-dev ---
# The pinned simulator: snapshots only match on the runtime that recorded them (TDD §9). Change both together and re-record.
SIM_NAME   ?= iPhone 17
SIM_OS     ?= 27.0
SIM_DEST   := platform=iOS Simulator,name=$(SIM_NAME),OS=$(SIM_OS)
export SIM_NAME SIM_OS
APPLE_DIR  := apple
PACKAGES   := IrisCore IrisCapture IrisUI IrisTelemetry
SWIFT_DIRS := $(APPLE_DIR)/Iris $(APPLE_DIR)/IrisWidgets $(APPLE_DIR)/IrisNotifications $(APPLE_DIR)/IrisMac $(APPLE_DIR)/Tests \
              $(foreach p,$(PACKAGES),$(APPLE_DIR)/Packages/$(p)/Sources $(APPLE_DIR)/Packages/$(p)/Tests)
# Build jobs cap: one number for every xcodebuild and swift run here, the release scripts (testflight.sh, mac-release.sh read SWIFT_JOBS, default 2) and apple-proof.
SWIFT_JOBS ?= 2
export SWIFT_JOBS
# Load caps for runs on a shared machine (the mini), the same as scripts/apple-proof.sh: low priority and 2 concurrent compile tasks. CI (CI set) has a runner of its own.
XCB_NICE   := $(if $(CI),,nice -n 10)
XCB_CAP    := $(if $(CI),,IDEBuildOperationMaxNumberOfConcurrentCompileTasks=$(SWIFT_JOBS))
DD         := $(CURDIR)/$(APPLE_DIR)/.dd.noindex
XCB        := $(XCB_NICE) xcodebuild -project $(APPLE_DIR)/Iris.xcodeproj -derivedDataPath $(DD) CODE_SIGNING_ALLOWED=NO -jobs $(SWIFT_JOBS) $(XCB_CAP)
# Machine budget (reset row 7b): every heavy Apple job runs through scripts/apple-slot (the Apple lock + the factory test slot on the mini,
# bare in CI); `APPLE_SIM` also shuts every simulator down when the job ends. Test runners are capped: one worker, one destination, 2 build jobs.
APPLE      := scripts/apple-slot
APPLE_SIM  := scripts/apple-slot --sim
XCB_TEST   := -parallel-testing-enabled NO -maximum-parallel-testing-workers 1

.PHONY: generate
generate: ## xcodegen: apple/project.yml -> apple/Iris.xcodeproj (gitignored)
	cd $(APPLE_DIR) && xcodegen generate --spec project.yml

.PHONY: theme
theme: ## Regenerate IrisUI/Theme from the pinned basalt-ui tokens
	cd $(APPLE_DIR)/tools && bun install --frozen-lockfile && bun gen-theme.ts

.PHONY: icons
icons: ## Render the iOS and Mac app icons from apple/branding/logo.svg
	cd $(APPLE_DIR)/tools && bun install --frozen-lockfile && bun gen-app-icons.ts

.PHONY: lint-apple
lint-apple: ## swift format lint --strict over every Swift source
	swift format lint --strict -r $(SWIFT_DIRS)

.PHONY: test-packages
test-packages: ## swift test per package (macOS host; the iOS-only snapshot tests run in `snapshots`)
	@$(APPLE) sh -c 'for p in $(PACKAGES); do echo "== $$p"; (cd $(APPLE_DIR)/Packages/$$p && swift test --jobs $(SWIFT_JOBS)) || exit 1; done'

.PHONY: build-apple
build-apple: generate ## xcodebuild build of every app scheme (Iris incl. both extensions on the simulator, IrisMac)
	@$(APPLE) $(MAKE) --no-print-directory _build-apple

.PHONY: _build-apple
_build-apple:
	$(XCB) -scheme Iris -destination '$(SIM_DEST)' build
	$(XCB) -scheme IrisMac -destination 'platform=macOS' build

.PHONY: check-apple
check-apple: ## Theme drift, string catalogs, swift format lint, swift test per package, build of all schemes, IrisMacTests
	@$(APPLE_SIM) $(MAKE) --no-print-directory _check-apple

.PHONY: _check-apple
_check-apple:
	cd $(APPLE_DIR)/tools && bun install --frozen-lockfile && bun gen-theme.ts --check
	$(MAKE) check-strings
	$(MAKE) lint-apple
	$(MAKE) test-packages
	$(MAKE) build-apple
	$(XCB) -scheme IrisMac -destination 'platform=macOS' $(XCB_TEST) test

.PHONY: snapshots
snapshots: ## IrisUI snapshot tests on the pinned simulator, in the app build's derived data so Textual compiles once (RECORD=1 re-records the references)
	@$(APPLE_SIM) sh -c 'cd $(APPLE_DIR)/Packages/IrisUI && TEST_RUNNER_RECORD=$(RECORD) $(XCB_NICE) xcodebuild test -scheme IrisUI -destination "$(SIM_DEST)" -derivedDataPath $(DD) $(XCB_CAP) $(XCB_TEST)'

.PHONY: uitest
uitest: generate ## XCUITest flows on the pinned simulator (-IrisFakeCapture); ONLY="<Class>[/<test>] ..." runs those (UNIT=1 adds IrisTests); the full suite is CI's: refused locally
	@if [ -z "$(ONLY)" ] && [ -z "$$CI" ] && [ -z "$$IRIS_FULL_UITEST" ]; then \
		echo "  make uitest without ONLY=<Class>[/<test>] is CI's job (.github/workflows/apple.yml runs the full suite); locally run one class."; \
		echo "  Explicit owner request only: IRIS_FULL_UITEST=1 make uitest"; exit 1; fi
	@$(APPLE_SIM) $(XCB) -scheme Iris -destination '$(SIM_DEST)' $(XCB_TEST) $(foreach c,$(ONLY),-only-testing:IrisUITests/$(c)) $(if $(and $(ONLY),$(UNIT)),-only-testing:IrisTests) test

# --- Agent verification (TDD §9/§10, D17): boot the pinned simulator, run the app, look at it. Output lands in .artifacts/ (gitignored). ---
# The pinned device's UDID, resolved lazily from SIM_NAME/SIM_OS; empty when that device does not exist.
SIM_RUNTIME = com.apple.CoreSimulator.SimRuntime.iOS-$(subst .,-,$(SIM_OS))
SIM_UDID    = $(shell xcrun simctl list devices available -j | jq -r --arg rt '$(SIM_RUNTIME)' --arg n '$(SIM_NAME)' '.devices[$$rt] // [] | map(select(.name == $$n)) | first | .udid // empty')
APP_BUNDLE  := com.jkrumm.iris
ARTIFACTS   := .artifacts
# `snapshot-ui` right after a launch times out ("remote automation session"); give the app time to settle first.
UI_SETTLE   ?= 8

.PHONY: sim
sim: ## Boot the pinned simulator and block until it is ready (bootstatus -b); it stays booted until `make sim-down`
	@$(APPLE) $(MAKE) --no-print-directory _sim

.PHONY: sim-down
sim-down: ## Shut every simulator down
	@xcrun simctl shutdown all

.PHONY: sim-slim
sim-slim: ## (Re)apply scripts/sim-slim to the pinned simulator (disables posters, News, Spotlight, widgets, Siri ... : ~11 GiB -> a fraction); SIM_MEASURE=1 also cold-boots it and prints the RSS
	@FORCE=1 $(APPLE) scripts/sim-slim
	@$(if $(SIM_MEASURE),$(APPLE_SIM) scripts/sim-slim --measure)

.PHONY: _sim
_sim:
	@$(if $(CI),,scripts/sim-slim)
	@u="$(SIM_UDID)"; [ -n "$$u" ] || { echo "  no simulator '$(SIM_NAME)' on iOS $(SIM_OS) (xcrun simctl list devices available)"; exit 1; }; \
	xcrun simctl boot "$$u" 2>/dev/null || true; \
	xcrun simctl bootstatus "$$u" -b >/dev/null; \
	echo "  simulator $(SIM_NAME) iOS $(SIM_OS) ready ($$u)"

.PHONY: run-sim
run-sim: generate ## Build Iris for the pinned simulator, install, launch (-IrisFakeCapture), print the pid; the simulator is shut down after (KEEP_SIM=1 keeps it)
	@$(APPLE_SIM) $(MAKE) --no-print-directory _run-sim

.PHONY: _run-sim
_run-sim: _sim
	$(XCB) -scheme Iris -destination 'platform=iOS Simulator,id=$(SIM_UDID)' build
	xcrun simctl install $(SIM_UDID) "$(APPLE_DIR)/.dd.noindex/Build/Products/Debug-iphonesimulator/Iris.app"
	xcrun simctl terminate $(SIM_UDID) $(APP_BUNDLE) 2>/dev/null || true
	xcrun simctl launch $(SIM_UDID) $(APP_BUNDLE) -IrisFakeCapture

.PHONY: screenshot
screenshot: ## Full-resolution PNG of the pinned simulator -> .artifacts/screenshot-<time>.png (NAME=<label> to rename; KEEP_SIM=1 keeps it booted)
	@$(APPLE_SIM) $(MAKE) --no-print-directory _screenshot

.PHONY: _screenshot
_screenshot: _sim
	@mkdir -p $(ARTIFACTS)
	@f="$(ARTIFACTS)/$(or $(NAME),screenshot-$$(date +%H%M%S)).png"; xcrun simctl io $(SIM_UDID) screenshot "$$f" 2>/dev/null && echo "  $$f"

.PHONY: ui-snapshot
ui-snapshot: ## Semantic UI element tree of the foreground app -> .artifacts/ui-snapshot.txt (refs e1, e2 ... for scripts/mbm tap; KEEP_SIM=1 keeps it booted)
	@$(APPLE_SIM) $(MAKE) --no-print-directory _ui-snapshot

.PHONY: _ui-snapshot
_ui-snapshot: _sim
	@mkdir -p $(ARTIFACTS)
	@sleep $(UI_SETTLE)
	@scripts/mbm ui-automation snapshot-ui --simulator-id $(SIM_UDID) > $(ARTIFACTS)/ui-snapshot.txt
	@cat $(ARTIFACTS)/ui-snapshot.txt

.PHONY: proof-apple
proof-apple: generate ## A verifier's proof of an Apple change in one slot: iOS simulator screenshot + UI tree, Mac window PNGs -> .artifacts/proof/<time>/ (PROOF_IOS=0 / PROOF_MAC=0 skip a half)
	@$(APPLE_SIM) scripts/apple-proof.sh

# --- Device (the paired iPhone; TDD §13, skill `device`). Every xcodebuild/devicectl job goes through scripts/apple-slot (the targets do it themselves). ---
# DEVICE_SIGNING=paid (default: the paid team, headless with the ASC Team key from op://mini/apple-developer, entitlements as tracked) | personal
# (the free Personal Team Xcode knows, no Push/App Groups); TEAM=<id> overrides the team; IRIS_DEVICE_ID overrides the phone. Nothing here is
# tracked: team, key and device resolve at runtime (scripts/device-lib.sh).
# --- TestFlight (Wave 22 P2, skill `apple-dev`). Through scripts/apple-slot like every xcodebuild job (the poller's release hook wraps its whole make call the same way). ---
# UPLOAD=0 (default until the App Store Connect app record exists): a signed .ipa in .artifacts/testflight/export; UPLOAD=1: export and upload.
# Team id and the ASC Team key come from op://mini/apple-developer via secrets-run (scripts/apple-signing-key.sh); CFBundleVersion = <commit count>.<UTC epoch hours> (a same-sha rebuild still gets a new number).
UPLOAD ?= 0
.PHONY: testflight
testflight: ## Archive Iris (Release), export a signed .ipa (UPLOAD=0, default) or upload to TestFlight (UPLOAD=1)
	@UPLOAD=$(UPLOAD) $(APPLE) scripts/testflight.sh

.PHONY: device-build
device-build: generate ## Signed Debug build of Iris + extensions for the paired iPhone (first run registers the device)
	@$(APPLE) scripts/device-build.sh

.PHONY: device-run
device-run: ## Install the last device build on the iPhone, launch it (ARGS="-flag ..." go to the app), screenshot -> .artifacts/device-<time>.png
	@$(APPLE) scripts/device-run.sh $(ARGS)

.PHONY: device-screenshot
device-screenshot: ## Full-resolution PNG of the iPhone -> .artifacts/device-<time>.png (NAME=<label> to rename)
	scripts/device-screenshot.sh $(NAME)

.PHONY: device
device: ## Build, sign, install, launch and screenshot Iris on the paired iPhone (in sequence, also under make -j)
	@$(APPLE) $(MAKE) --no-print-directory _device

.PHONY: _device
_device:
	$(MAKE) device-build
	$(MAKE) device-run

# --- Mac release (TDD §5 "Updates", skill `apple-dev`). Through scripts/apple-slot like every xcodebuild job. ---
# IDENTITY=development (Apple Development, no notarization, draft only) | developer-id (notarized + stapled; needs the certificate in the keychain);
# PUBLISH=draft (never served as releases/latest) | release. SIGNING_ONLY=1 stops after the signature check.
.PHONY: mac-release
mac-release: ## Sign, zip and publish a Sparkle release of IrisMac: IDENTITY=development|developer-id [PUBLISH=draft|release]
	@$(APPLE) scripts/mac-release.sh

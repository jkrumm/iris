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
HEALTH_URL   := http://127.0.0.1:7730/health
AUDIO_DOOR_HEALTH_URL := http://127.0.0.1:7792/health
LINES        ?= 100

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-14s %s\n", $$1, $$2}'

# check-apple needs Xcode; it joins `check` only where xcodebuild exists (the Linux CI job has none, apple.yml runs it).
CHECK_APPLE := $(if $(shell command -v xcodebuild 2>/dev/null),check-apple)

.PHONY: check
check: check-server check-contracts guard $(CHECK_APPLE) ## Everything CI runs except e2e (check-apple joins where Xcode exists)

.PHONY: check-server
check-server: ## oxlint, oxfmt --check, tsc --noEmit, bun test
	cd server && bun install --frozen-lockfile
	cd server && bun run lint
	cd server && bun run format:check
	cd server && bun run typecheck
	cd server && bun run test

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
launchd-install: ## Render the plist templates (__HOME__ substituted) and (re)load both LaunchAgents
	@mkdir -p "$(LAUNCHAGENTS)" "$(HOME)/Library/Logs"
	@sed "s|__HOME__|$(HOME)|g" "$(LAUNCHD_DIR)/$(LABEL).plist.template" > "$(LAUNCHAGENTS)/$(LABEL).plist"
	@sed "s|__HOME__|$(HOME)|g" "$(LAUNCHD_DIR)/$(LABEL_DEPLOY).plist.template" > "$(LAUNCHAGENTS)/$(LABEL_DEPLOY).plist"
	@launchctl bootout "gui/$$(id -u)/$(LABEL)" 2>/dev/null || true
	@launchctl bootstrap "gui/$$(id -u)" "$(LAUNCHAGENTS)/$(LABEL).plist"
	@launchctl bootout "gui/$$(id -u)/$(LABEL_DEPLOY)" 2>/dev/null || true
	@launchctl bootstrap "gui/$$(id -u)" "$(LAUNCHAGENTS)/$(LABEL_DEPLOY).plist"
	@rm -f "$(HOME)/.iris/launchd-pending"
	@echo "installed $(LABEL), $(LABEL_DEPLOY)"

.PHONY: launchd-uninstall
launchd-uninstall: ## Unload and remove both LaunchAgents
	@launchctl bootout "gui/$$(id -u)/$(LABEL_DEPLOY)" 2>/dev/null || true
	@launchctl bootout "gui/$$(id -u)/$(LABEL)" 2>/dev/null || true
	@rm -f "$(HOME)/.local/state/jobs/$(LABEL_DEPLOY).json"
	@rm -f "$(LAUNCHAGENTS)/$(LABEL_DEPLOY).plist" "$(LAUNCHAGENTS)/$(LABEL).plist"
	@echo "removed $(LABEL), $(LABEL_DEPLOY)"

.PHONY: launchd-status
launchd-status: ## launchctl state for both LaunchAgents + curl /health
	@launchctl print "gui/$$(id -u)/$(LABEL)" 2>&1 | head -n 30
	@echo ""
	@launchctl print "gui/$$(id -u)/$(LABEL_DEPLOY)" 2>&1 | head -n 20
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
	@tail -n 100 -f "$(HOME)/Library/Logs/iris.log" "$(HOME)/Library/Logs/iris.err" "$(HOME)/Library/Logs/iris-deploy.log"

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
APPLE_DIR  := apple
PACKAGES   := IrisCore IrisCapture IrisUI IrisTelemetry
SWIFT_DIRS := $(APPLE_DIR)/Iris $(APPLE_DIR)/IrisWidgets $(APPLE_DIR)/IrisNotifications $(APPLE_DIR)/IrisMac $(APPLE_DIR)/Tests \
              $(foreach p,$(PACKAGES),$(APPLE_DIR)/Packages/$(p)/Sources $(APPLE_DIR)/Packages/$(p)/Tests)
XCB        := xcodebuild -project $(APPLE_DIR)/Iris.xcodeproj -derivedDataPath $(APPLE_DIR)/.dd CODE_SIGNING_ALLOWED=NO

.PHONY: generate
generate: ## xcodegen: apple/project.yml -> apple/Iris.xcodeproj (gitignored)
	cd $(APPLE_DIR) && xcodegen generate --spec project.yml

.PHONY: theme
theme: ## Regenerate IrisUI/Theme from the pinned basalt-ui tokens
	cd $(APPLE_DIR)/tools && bun install --frozen-lockfile && bun gen-theme.ts

.PHONY: lint-apple
lint-apple: ## swift format lint --strict over every Swift source
	swift format lint --strict -r $(SWIFT_DIRS)

.PHONY: test-packages
test-packages: ## swift test per package (macOS host; the iOS-only snapshot tests run in `snapshots`)
	@for p in $(PACKAGES); do echo "== $$p"; (cd $(APPLE_DIR)/Packages/$$p && swift test) || exit 1; done

.PHONY: build-apple
build-apple: generate ## xcodebuild build of every app scheme (Iris incl. both extensions on the simulator, IrisMac)
	$(XCB) -scheme Iris -destination '$(SIM_DEST)' build
	$(XCB) -scheme IrisMac -destination 'platform=macOS' build

.PHONY: check-apple
check-apple: ## Theme drift, swift format lint, swift test per package, build of all schemes
	cd $(APPLE_DIR)/tools && bun install --frozen-lockfile && bun gen-theme.ts --check
	$(MAKE) lint-apple
	$(MAKE) test-packages
	$(MAKE) build-apple

.PHONY: snapshots
snapshots: ## IrisUI snapshot tests on the pinned simulator (RECORD=1 make snapshots re-records the references)
	cd $(APPLE_DIR)/Packages/IrisUI && TEST_RUNNER_RECORD=$(RECORD) xcodebuild test -scheme IrisUI -destination '$(SIM_DEST)' -derivedDataPath .dd

.PHONY: uitest
uitest: generate ## XCUITest smoke flows on the pinned simulator (launches with -IrisFakeCapture)
	$(XCB) -scheme Iris -destination '$(SIM_DEST)' test

# --- Agent verification (TDD §9/§10, D17): boot the pinned simulator, run the app, look at it. Output lands in .artifacts/ (gitignored). ---
# The pinned device's UDID, resolved lazily from SIM_NAME/SIM_OS; empty when that device does not exist.
SIM_RUNTIME = com.apple.CoreSimulator.SimRuntime.iOS-$(subst .,-,$(SIM_OS))
SIM_UDID    = $(shell xcrun simctl list devices available -j | jq -r --arg rt '$(SIM_RUNTIME)' --arg n '$(SIM_NAME)' '.devices[$$rt] // [] | map(select(.name == $$n)) | first | .udid // empty')
APP_BUNDLE  := com.jkrumm.iris
ARTIFACTS   := .artifacts
# `snapshot-ui` right after a launch times out ("remote automation session"); give the app time to settle first.
UI_SETTLE   ?= 8

.PHONY: sim
sim: ## Boot the pinned simulator and block until it is ready (bootstatus -b)
	@u="$(SIM_UDID)"; [ -n "$$u" ] || { echo "  no simulator '$(SIM_NAME)' on iOS $(SIM_OS) (xcrun simctl list devices available)"; exit 1; }; \
	xcrun simctl boot "$$u" 2>/dev/null || true; \
	xcrun simctl bootstatus "$$u" -b >/dev/null; \
	echo "  simulator $(SIM_NAME) iOS $(SIM_OS) ready ($$u)"

.PHONY: run-sim
run-sim: generate sim ## Build Iris for the pinned simulator, install, launch (-IrisFakeCapture), print the pid
	$(XCB) -scheme Iris -destination 'platform=iOS Simulator,id=$(SIM_UDID)' build
	xcrun simctl install $(SIM_UDID) "$(APPLE_DIR)/.dd/Build/Products/Debug-iphonesimulator/Iris.app"
	xcrun simctl terminate $(SIM_UDID) $(APP_BUNDLE) 2>/dev/null || true
	xcrun simctl launch $(SIM_UDID) $(APP_BUNDLE) -IrisFakeCapture

.PHONY: screenshot
screenshot: sim ## Full-resolution PNG of the pinned simulator -> .artifacts/screenshot-<time>.png (NAME=<label> to rename)
	@mkdir -p $(ARTIFACTS)
	@f="$(ARTIFACTS)/$(or $(NAME),screenshot-$$(date +%H%M%S)).png"; xcrun simctl io $(SIM_UDID) screenshot "$$f" 2>/dev/null && echo "  $$f"

.PHONY: ui-snapshot
ui-snapshot: sim ## Semantic UI element tree of the foreground app -> .artifacts/ui-snapshot.txt (refs e1, e2 ... for scripts/mbm tap)
	@mkdir -p $(ARTIFACTS)
	@sleep $(UI_SETTLE)
	@scripts/mbm ui-automation snapshot-ui --simulator-id $(SIM_UDID) > $(ARTIFACTS)/ui-snapshot.txt
	@cat $(ARTIFACTS)/ui-snapshot.txt

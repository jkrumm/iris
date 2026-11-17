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
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-14s %s\n", $$1, $$2}'

# check-apple needs Xcode; it joins `check` only where xcodebuild exists (the Linux CI job has none, apple.yml runs it).
CHECK_APPLE := $(if $(shell command -v xcodebuild 2>/dev/null),check-apple)

.PHONY: check
check: check-server check-contracts check-strings check-web guard $(CHECK_APPLE) ## Everything CI runs except e2e (check-apple joins where Xcode exists)

# The lead's tier (project.yaml `checks.fast`): everything `check` runs except the simulator-free-but-heavy Apple parts, which CI proves on the exact head
# (apple.yml: check-apple, snapshots, uitest on hosted xcode-27; `make merge-guard` demands its green run when the branch touches its paths).
# Web: the Playwright e2e is CI's `web` job (WEB_E2E=0). Apple: theme drift and swift format lint always where swift exists; swift test of the packages only when the branch changed apple/.
CHECK_FAST_APPLE := $(if $(shell command -v swift 2>/dev/null),check-fast-apple)

.PHONY: check-fast
check-fast: check-server check-contracts check-strings guard $(CHECK_FAST_APPLE) ## Lead tier: server, contracts, strings, web (no e2e), guard, Apple theme drift + lint (+ package tests if apple/ changed); CI runs the full gate
	$(MAKE) --no-print-directory check-web WEB_E2E=0

.PHONY: check-fast-apple
check-fast-apple:
	cd $(APPLE_DIR)/tools && bun install --frozen-lockfile && bun gen-theme.ts --check
	$(MAKE) --no-print-directory lint-apple
	@if git diff --quiet origin/master...HEAD -- $(APPLE_DIR) 2>/dev/null && git diff --quiet HEAD -- $(APPLE_DIR) 2>/dev/null; then \
		echo "  apple/ unchanged against origin/master: swift test of the packages is CI's"; \
	else $(MAKE) --no-print-directory test-packages; fi

.PHONY: check-server
check-server: ## oxlint, oxfmt --check, tsc --noEmit, bun test (server and scripts)
	cd server && bun install --frozen-lockfile
	cd server && bun run lint
	cd server && bun run format:check
	cd server && bun run typecheck
	cd server && bun run test
	bun test scripts

# --- Web renderer (web/, the page the WebView island loads; AGENTS.md "Web renderer") ---
# Screenshot baselines are Linux renders: WEB_VISUAL=1 compares them (default on Linux), 0 runs only the non-visual e2e (network, CSP, height).
WEB_VISUAL ?= $(if $(filter Linux,$(shell uname -s)),1,0)
# WEB_E2E=0 skips Playwright inside check-web (CI's bare `check` job: the `web` job runs the e2e in the Playwright image). check-web installs Chromium itself (no apt).
WEB_E2E ?= 1
# The Playwright image tag must equal the @playwright/test version pinned in web/package.json.
PLAYWRIGHT_VERSION := 1.65.0
PLAYWRIGHT_IMAGE   := mcr.microsoft.com/playwright:v$(PLAYWRIGHT_VERSION)-noble
# Runs in the image on a copy-free mount: node_modules and the build dirs are masked with anonymous volumes so the host's (macOS) ones stay untouched.
WEB_DOCKER := docker run --rm --ipc=host -v "$(CURDIR)":/work -v /work/web/node_modules -v /work/web/dist -v /work/web/dist-harness -w /work $(PLAYWRIGHT_IMAGE) \
	sh -c 'npm install -g bun@1.4.2 >/dev/null 2>&1 && cd web && bun install --frozen-lockfile &&

.PHONY: web-build
web-build: ## Build web/ and sync it into apple/Packages/IrisUI/.../Resources/Artifact (island.* stay); commit the result
	cd web && bun install --frozen-lockfile && bun run sync

.PHONY: check-web
check-web: ## web/: oxlint, oxfmt --check, tsc, unit tests, bundle drift + size budget, Playwright e2e (screenshots only with WEB_VISUAL=1)
	cd web && bun install --frozen-lockfile
	cd web && bun run lint
	cd web && bun run format:check
	cd web && bun run typecheck
	cd web && bun run test
	cd web && bun run build:check
	@if [ "$(WEB_E2E)" = "0" ]; then echo "  web e2e skipped (WEB_E2E=0: the CI web job runs it in the Playwright image)"; else \
	  if [ "$(WEB_VISUAL)" = "0" ]; then echo "  web visual snapshots skipped (WEB_VISUAL=0: baselines are Linux renders; make web-check-linux compares them)"; fi; \
	  cd web && bunx playwright install chromium && WEB_VISUAL=$(WEB_VISUAL) bun run test:e2e; \
	fi

.PHONY: web-snapshots
web-snapshots: ## Re-record the Linux screenshot baselines (web/tests/__screenshots__) in the pinned Playwright image
	$(WEB_DOCKER) WEB_VISUAL=1 bun run test:e2e:update'

.PHONY: web-check-linux
web-check-linux: ## The Linux build must equal the committed bundle, then the e2e with screenshot comparison, in the pinned Playwright image
	$(WEB_DOCKER) bun run build:check && WEB_VISUAL=1 bun run test:e2e'

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

# The Apple targets and variables live in apple/Makefile.mk: apple.yml filters on that file, so a web or server Makefile edit does not run the Apple jobs.
include apple/Makefile.mk

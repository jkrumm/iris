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
LINES        ?= 100

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-14s %s\n", $$1, $$2}'

.PHONY: check
check: check-server ## Everything CI runs (check-apple joins when apple/ exists)

.PHONY: check-server
check-server: ## oxlint, oxfmt --check, tsc --noEmit, bun test
	cd server && bun install --frozen-lockfile
	cd server && bun run lint
	cd server && bun run format:check
	cd server && bun run typecheck
	cd server && bun run test

.PHONY: format
format: ## Apply oxfmt
	cd server && bun run format

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

.PHONY: logs
logs: ## Bounded tail (last $(LINES) lines) of the production logs, then exits (no -f)
	@tail -n $(LINES) "$(HOME)/Library/Logs/iris.log" "$(HOME)/Library/Logs/iris.err" "$(HOME)/Library/Logs/iris-deploy.log"

.PHONY: smoke
smoke: ## Send a real German recording end to end (IRIS_URL=https://iris.mini.<domain> AUDIO=<file>); needs the mini
	@./scripts/smoke.sh

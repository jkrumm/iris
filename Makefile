.DEFAULT_GOAL := help

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

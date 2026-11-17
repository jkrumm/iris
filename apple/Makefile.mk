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
# In CI only: an xcodebuild test run that died of the hosted runner (no simulator found, the UI-test runner never bootstrapped) runs once more;
# a run with a failed test of its own never does (scripts/xcb-retry, Issue 1650).
XCB_RETRY  := $(if $(CI),$(CURDIR)/scripts/xcb-retry)

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
	$(XCB_RETRY) $(XCB) -scheme IrisMac -destination 'platform=macOS' $(XCB_TEST) test

.PHONY: snapshots
snapshots: ## IrisUI snapshot tests on the pinned simulator, in the app build's derived data so Textual compiles once (RECORD=1 re-records the references)
	@$(APPLE_SIM) sh -c 'cd $(APPLE_DIR)/Packages/IrisUI && TEST_RUNNER_RECORD=$(RECORD) $(XCB_RETRY) $(XCB_NICE) xcodebuild test -scheme IrisUI -destination "$(SIM_DEST)" -derivedDataPath $(DD) $(XCB_CAP) $(XCB_TEST)'

.PHONY: uitest
uitest: generate ## XCUITest flows on the pinned simulator (-IrisFakeCapture); ONLY="<Class>[/<test>] ..." runs those (UNIT=1 adds IrisTests); the full suite is CI's: refused locally
	@if [ -z "$(ONLY)" ] && [ -z "$$CI" ] && [ -z "$$IRIS_FULL_UITEST" ]; then \
		echo "  make uitest without ONLY=<Class>[/<test>] is CI's job (.github/workflows/apple.yml runs the full suite); locally run one class."; \
		echo "  Explicit owner request only: IRIS_FULL_UITEST=1 make uitest"; exit 1; fi
	@$(APPLE_SIM) $(XCB_RETRY) $(XCB) -scheme Iris -destination '$(SIM_DEST)' $(XCB_TEST) $(foreach c,$(ONLY),-only-testing:IrisUITests/$(c)) $(if $(and $(ONLY),$(UNIT)),-only-testing:IrisTests) test

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
	@$(if $(CI),,scripts/sim-slim || echo "  sim-slim failed, the simulator boots stock")
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
# Team id and the ASC Team key come from op://mini/apple-developer via secrets-run (scripts/apple-signing-key.sh); CFBundleVersion = <commit count>.<UTC epoch hours> (a same-sha rebuild still gets a new number);
# the marketing version is `bun scripts/version.ts` (the Mac release of the same sha gets the same one). DRY_RUN=1 prints version, build and notes only.
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
# PUBLISH=draft (never served as releases/latest) | release. SIGNING_ONLY=1 stops after the signature check. DRY_RUN=1 prints the version, the tag
# and the release notes only. The tag is mac-v<version>-<build>; the notes (the apple/ commit subjects since the previous release) go in the appcast and the release body.
.PHONY: mac-release
mac-release: ## Sign, zip and publish a Sparkle release of IrisMac: IDENTITY=development|developer-id [PUBLISH=draft|release]
	@$(APPLE) scripts/mac-release.sh

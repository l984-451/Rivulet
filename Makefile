# Rivulet developer workflow wrappers.
# Run `make` or `make help` to list targets.

SCHEME      := Rivulet
DESTINATION := platform=tvOS Simulator,name=Apple TV
# Optional curated test plan. If Rivulet.xctestplan is present at the repo root
# it is used; otherwise `make test` falls back to the scheme's default tests
# (the full RivuletTests suite), so the target works with or without the plan.
TESTPLAN    := Rivulet.xctestplan

.DEFAULT_GOAL := help
.PHONY: help bootstrap lint format format-check test build

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Install toolchain (brew bundle) and git hooks (pre-commit)
	@command -v brew >/dev/null 2>&1 \
		|| { echo "Homebrew not found. Install from https://brew.sh, then re-run."; exit 1; }
	brew bundle
	@command -v pre-commit >/dev/null 2>&1 \
		|| { echo "pre-commit not found after brew bundle. Check the Brewfile."; exit 1; }
	pre-commit install

lint: ## Run SwiftLint (matches CI: --strict)
	@command -v swiftlint >/dev/null 2>&1 \
		|| { echo "swiftlint not found. Run 'make bootstrap' or 'brew bundle'."; exit 1; }
	swiftlint lint --strict

format: ## Format Swift sources in place (SwiftFormat)
	@command -v swiftformat >/dev/null 2>&1 \
		|| { echo "swiftformat not found. Run 'make bootstrap' or 'brew bundle'."; exit 1; }
	swiftformat .

format-check: ## Check formatting without writing changes
	@command -v swiftformat >/dev/null 2>&1 \
		|| { echo "swiftformat not found. Run 'make bootstrap' or 'brew bundle'."; exit 1; }
	swiftformat . --lint

# Uses $(TESTPLAN) if present, else the scheme's default tests.
# xcbeautify is optional: fall back to raw xcodebuild if it's absent.
test: ## Run tests on the tvOS Simulator (uses the test plan if present, else scheme default)
	@plan_arg=""; \
	if [ -f "$(TESTPLAN)" ]; then plan_arg="-testPlan $$(basename "$(TESTPLAN)" .xctestplan)"; fi; \
	if command -v xcbeautify >/dev/null 2>&1; then \
		set -o pipefail; \
		xcodebuild test -scheme "$(SCHEME)" -destination "$(DESTINATION)" $$plan_arg | xcbeautify; \
	else \
		echo "xcbeautify not found; using raw xcodebuild output."; \
		xcodebuild test -scheme "$(SCHEME)" -destination "$(DESTINATION)" $$plan_arg; \
	fi

build: ## Build for the tvOS Simulator
	@if command -v xcbeautify >/dev/null 2>&1; then \
		set -o pipefail; \
		xcodebuild build -scheme "$(SCHEME)" -destination "$(DESTINATION)" | xcbeautify; \
	else \
		xcodebuild build -scheme "$(SCHEME)" -destination "$(DESTINATION)"; \
	fi

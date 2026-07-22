# Rivulet developer workflow wrappers.
# Run `make` or `make help` to list targets.

SCHEME      := Rivulet
DESTINATION := platform=tvOS Simulator,name=Apple TV
# Shared naming contract: the test plan and some tools land on other branches
# that aren't merged to main yet. These targets are written to work once
# everything is on main.
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

lint: ## Run SwiftLint (config/baseline auto-discovered)
	@command -v swiftlint >/dev/null 2>&1 \
		|| { echo "swiftlint not found. Run 'make bootstrap' or 'brew bundle'."; exit 1; }
	swiftlint lint

format: ## Format Swift sources in place (SwiftFormat)
	@command -v swiftformat >/dev/null 2>&1 \
		|| { echo "swiftformat not found. Run 'make bootstrap' or 'brew bundle'."; exit 1; }
	swiftformat .

format-check: ## Check formatting without writing changes
	@command -v swiftformat >/dev/null 2>&1 \
		|| { echo "swiftformat not found. Run 'make bootstrap' or 'brew bundle'."; exit 1; }
	swiftformat . --lint

# Depends on $(TESTPLAN), which arrives via another branch (see note above).
# xcbeautify is optional: fall back to raw xcodebuild if it's absent.
test: ## Run the test plan on the tvOS Simulator
	@if command -v xcbeautify >/dev/null 2>&1; then \
		set -o pipefail; \
		xcodebuild test -scheme "$(SCHEME)" -destination "$(DESTINATION)" -testPlan "$(TESTPLAN)" | xcbeautify; \
	else \
		echo "xcbeautify not found; using raw xcodebuild output."; \
		xcodebuild test -scheme "$(SCHEME)" -destination "$(DESTINATION)" -testPlan "$(TESTPLAN)"; \
	fi

build: ## Build for the tvOS Simulator
	@if command -v xcbeautify >/dev/null 2>&1; then \
		set -o pipefail; \
		xcodebuild build -scheme "$(SCHEME)" -destination "$(DESTINATION)" | xcbeautify; \
	else \
		xcodebuild build -scheme "$(SCHEME)" -destination "$(DESTINATION)"; \
	fi

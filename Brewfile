# Rivulet developer toolchain.
# Install with: brew bundle
#
# NOTE: CI pins swiftlint to 0.65.0 (see .swiftlint.yml / CI config).
# Homebrew installs the current formula and can't easily pin an exact
# version, so match CI locally if lint results diverge:
#   brew unlink swiftlint && brew install swiftlint@0.65.0   # if a tap provides it
# or install 0.65.0 from source. Mismatched versions can surface
# different lint diagnostics than CI.

brew "swiftlint"  # CI pins 0.65.0 — keep local close to avoid drift
brew "swiftformat"
brew "pre-commit"
brew "xcbeautify"
brew "gh"

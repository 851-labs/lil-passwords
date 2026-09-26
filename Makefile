.PHONY: project build test e2e format lint

# 851-2441: SWIFT_DETERMINISTIC_HASHING=1 pins Swift's per-process Dictionary/Set hash seed.
# Without it, xcodegen's project.pbxproj output for this target is nondeterministic across runs
# whenever more than one PBXCopyFilesBuildPhase-with-distinct-destination exists on one target —
# confirmed by generating three times in a row and diffing. That became possible the moment a
# second embed destination (Contents/PlugIns, for AutoFillExtension) joined the pre-existing
# Contents/Helpers embed: xcodegen orders the two "Embed Dependencies" phases via a hash-ordered
# collection internally, so their relative position flips from run to run with plain hashing. CI's
# "Check generated project is up to date" step (.github/workflows/ci.yml) runs this same `make
# project`, so a flip there would spuriously fail the diff against whatever order happened to get
# committed — pinning the seed here (and only here, so every generation, local or CI, agrees) is
# what keeps that check meaningful instead of a coin flip.
project:
	SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate

build:
	xcodebuild -project LilPasswords.xcodeproj -scheme LilPasswords -configuration Debug -derivedDataPath build build

test:
	swift test --package-path Packages/LilPasswordsKit

# 851-2434: end-to-end tests that run the *built* lilpass binary as a subprocess against a
# disposable, in-memory-vault-backed helper (LilpassE2EHelper) over a real, uniquely-named XPC Mach
# service — never the real "lil passwords" app, its real vault store, or the real keychain item.
# Depends on `build` so `LILPASS_E2E_BINARY_PATH` always points at a freshly built lilpass.
# E2E_EXTRA_ARGS is empty by default (kept out of normal local runs' output) — CI sets it to
# `--verbose` for extra `swift test` diagnostics while chasing 851-2434's CI-only hang.
#
# --no-parallel: cheap insurance, not the fix for 851-2434's CI-only hang. Each suite here already
# carries `.serialized`, but that trait only serializes tests *within* one suite — swift-testing
# still runs separate suites concurrently with each other by default, and an early CI run's
# HangWatchdog dump caught exactly that: five suites' `init()`s interleaving within milliseconds of
# each other, racing to instantiate the same generic metadata for the first time
# (`swift::MetadataCacheEntryBase::awaitSatisfyingState`). `--no-parallel` removes that race by
# running one suite (and one test) at a time for the whole package. It was believed for a while to be
# the actual fix — it wasn't: a CI run with `--no-parallel` in place still livelocked 3 times in a
# row, always partway through `MCPStdioSessionTests`, with every suite's `init()` demonstrably running
# strictly one at a time. See that suite's doc comment (`Packages/LilpassE2E/Tests/LilpassE2ETests/
# MCPStdioSessionTests.swift`) for the full diagnostic history and the two real, stacked root causes
# that were actually inside that suite's own teardown: a leaked MCP `Client` background `Task` (fixed
# by calling `disconnect()`), and a blocking `Process.waitUntilExit()` call starving Swift
# Concurrency's cooperative thread pool from inside `async` code (fixed by polling `isRunning` with
# `Task.sleep` instead). `--no-parallel` and every suite's `.serialized` trait stay on anyway — they
# guard against the race they were originally built for, which is real even if it wasn't this bug —
# but don't mistake either one for why `make e2e` reliably passes now; the two fixes in
# `MCPStdioSessionTests.swift` are why.
#
# This target deliberately does *not* retry on failure — a hang here should surface immediately to
# whoever's running it locally, not get silently swallowed. CI's E2E step (.github/workflows/ci.yml)
# retries a few times instead, as defense in depth against any residual flakiness, while keeping
# every attempt's HangWatchdog tracing in the log.
e2e: build
	swift build --package-path Packages/LilpassE2E --product LilpassE2EHelper
	LILPASS_E2E_BINARY_PATH="$(CURDIR)/build/Build/Products/Debug/lil passwords.app/Contents/Helpers/lilpass" \
	LILPASS_E2E_HELPER_BINARY_PATH="$$(swift build --package-path Packages/LilpassE2E --product LilpassE2EHelper --show-bin-path)/LilpassE2EHelper" \
	swift test --package-path Packages/LilpassE2E --no-parallel $(E2E_EXTRA_ARGS)

format:
	xcrun swift-format format --in-place --recursive App Agent CLI AutoFillExtension Packages

lint:
	xcrun swift-format lint --strict --recursive App Agent CLI AutoFillExtension Packages
	scripts/check-localization.sh

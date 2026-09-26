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
# --no-parallel: required, not a nicety. Each suite here already carries `.serialized`, but that
# trait only serializes the tests *within* one suite — swift-testing still runs separate suites
# concurrently with each other by default, and this package's suites all construct an
# E2EHelperProcess/run the lilpass binary via the same generic Process/Pipe machinery
# (LilpassBinary/E2EHelperProcess). A CI run with the HangWatchdog instrumentation below (added
# alongside this flag) caught it directly: five suites' `init()`s interleaved within milliseconds of
# each other, then every thread livelocked in the Swift runtime's generic-metadata cache
# (`swift::MetadataCacheEntryBase::awaitSatisfyingState`/`getOrInsert`/`MetadataCacheKey::operator==`)
# — the same first-time-generic-instantiation race `MCPStdioSessionTests`'s doc comment already
# describes, just racing across suites instead of within one. `--no-parallel` runs one suite (and
# one test) at a time for the whole package, which is the only thing that actually removes the
# cross-suite race; the per-suite `.serialized` traits stay as defense in depth for anyone who runs
# a single suite directly (e.g. via `--filter`) without this flag.
#
# `--no-parallel` is a substantial improvement, not a guaranteed cure: of several local
# `make e2e --no-parallel` runs taken while verifying this fix, all but one passed cleanly in
# ~13-14s, but one still tripped HangWatchdog — the same generic-metadata-cache symptom, just far
# rarer now than "every run" (its prior, pre-`--no-parallel`, cross-suite-interleaved form). This
# target deliberately does *not* retry on failure — a hang here should surface immediately to
# whoever's running it locally, not get silently swallowed. CI's E2E step (.github/workflows/ci.yml)
# does retry a few times instead, as defense in depth against this residual rarity, while keeping
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

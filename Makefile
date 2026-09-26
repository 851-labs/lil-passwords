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
e2e: build
	swift build --package-path Packages/LilpassE2E --product LilpassE2EHelper
	LILPASS_E2E_BINARY_PATH="$(CURDIR)/build/Build/Products/Debug/lil passwords.app/Contents/Helpers/lilpass" \
	LILPASS_E2E_HELPER_BINARY_PATH="$$(swift build --package-path Packages/LilpassE2E --product LilpassE2EHelper --show-bin-path)/LilpassE2EHelper" \
	swift test --package-path Packages/LilpassE2E

format:
	xcrun swift-format format --in-place --recursive App Agent CLI AutoFillExtension Packages

lint:
	xcrun swift-format lint --strict --recursive App Agent CLI AutoFillExtension Packages
	scripts/check-localization.sh

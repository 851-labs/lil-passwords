.PHONY: project build test format lint

project:
	xcodegen generate

build:
	xcodebuild -project LilPasswords.xcodeproj -scheme LilPasswords -configuration Debug -derivedDataPath build build

test:
	swift test --package-path Packages/LilPasswordsKit

format:
	xcrun swift-format format --in-place --recursive App Agent CLI Packages

lint:
	xcrun swift-format lint --strict --recursive App Agent CLI Packages

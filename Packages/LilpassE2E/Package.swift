// swift-tools-version: 6.0
import PackageDescription

// 851-2434's end-to-end test suite: runs the *built* `lilpass` binary (and `lilpass mcp`) as real
// subprocesses against a disposable, in-memory-vault test helper, over a real cross-process XPC
// connection — see `Tests/LilpassE2ETests/Support` for how.
//
// A separate, sibling top-level package rather than more targets inside
// `Packages/LilPasswordsKit/Package.swift` on purpose:
//
// - `make test` (`swift test --package-path Packages/LilPasswordsKit`) stays exactly as fast and
//   as free of process-spawning/launchd side effects as it is today — this package doesn't exist
//   from that package's point of view at all.
// - `project.yml`/`LilPasswords.xcodeproj` need zero changes, so this doesn't touch the "generated
//   project is out of date" CI check. Nothing here ships inside the app, the helper, or `lilpass`.
//
// `make e2e` builds `LilpassE2EHelper` (see its own target below) and then runs this package's
// tests; see the Makefile and `.github/workflows/ci.yml`'s "E2E" step.
let package = Package(
  name: "LilpassE2E",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(path: "../LilPasswordsKit"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
  ],
  targets: [
    // A disposable stand-in for `LilPasswordsAgent`. `LilpassE2ETests` launches one per test via
    // `launchctl bootstrap` with a throwaway, per-test plist — never `launchctl setenv` or
    // anything else that could affect another agent's concurrent build/test run on this Mac (see
    // its own doc comment). Built as its own step by `make e2e` (not merely "however `swift test`
    // happens to build its dependencies") so its exact binary path is known up front.
    .executableTarget(
      name: "LilpassE2EHelper",
      dependencies: [
        .product(name: "LilPasswordsKit", package: "LilPasswordsKit")
      ]
    ),
    .testTarget(
      name: "LilpassE2ETests",
      dependencies: [
        .product(name: "LilPasswordsKit", package: "LilPasswordsKit"),
        .product(name: "LilpassCore", package: "LilPasswordsKit"),
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
  ]
)

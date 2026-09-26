// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LilPasswordsKit",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "LilPasswordsKit", targets: ["LilPasswordsKit"]),
    // The `lilpw` CLI's logic (item resolution, exit codes, command results), kept separate from
    // `LilPasswordsKit` itself so the CLI's concerns don't leak into the app/agent's shared core,
    // and separate from the CLI target (`CLI/Sources`, an XcodeGen `tool` target) so it's a plain
    // SwiftPM library `swift test` can exercise directly — see `LilpwCoreTests` for the in-process
    // `AgentServer` + `InMemoryVaultStore` harness this buys.
    .library(name: "LilpwCore", targets: ["LilpwCore"]),
  ],
  targets: [
    .target(
      name: "LilPasswordsKit",
      resources: [.copy("Resources/common-passwords.txt")],
      // VaultStore talks to the system sqlite3 C library directly (see docs/adr/0003-vaultstore.md)
      // rather than adding a dependency such as GRDB. `import SQLite3` alone is enough to see the
      // API on Apple platforms, but the library itself still needs an explicit link.
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
      name: "LilPasswordsKitTests",
      dependencies: ["LilPasswordsKit"],
      resources: [.copy("Fixtures")]
    ),
    // No swift-argument-parser dependency here on purpose: parsing lives in the CLI target
    // (`project.yml`'s `lilpw` target), which is the only place that needs it. `LilpwCore` only
    // ever sees already-parsed Swift values, so this package stays free of that dependency.
    .target(
      name: "LilpwCore",
      dependencies: ["LilPasswordsKit"]
    ),
    .testTarget(
      // Depends on `LilPasswordsKit` too (not just `LilpwCore`) so its tests can build the same
      // in-process `AgentServer` + `InMemoryVaultStore` + anonymous-`NSXPCListener` harness
      // `AgentXPCEndToEndTests` uses, via `@testable import LilPasswordsKit` for the test-only
      // `AgentClient(endpoint:connectionSecurity:)` initializer.
      name: "LilpwCoreTests",
      dependencies: ["LilpwCore", "LilPasswordsKit"]
    ),
  ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LilPasswordsKit",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "LilPasswordsKit", targets: ["LilPasswordsKit"])
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
  ]
)

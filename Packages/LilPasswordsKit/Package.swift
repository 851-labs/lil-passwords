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
      resources: [.copy("Resources/common-passwords.txt")]
    ),
    .testTarget(
      name: "LilPasswordsKitTests",
      dependencies: ["LilPasswordsKit"],
      resources: [.copy("Fixtures")]
    ),
  ]
)

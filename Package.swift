// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pluck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PluckCore"),
        .executableTarget(name: "Pluck", dependencies: ["PluckCore"]),
        .testTarget(name: "PluckCoreTests", dependencies: ["PluckCore"]),
    ],
    swiftLanguageModes: [.v5]
)

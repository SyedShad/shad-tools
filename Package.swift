// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShadTools",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ShadTools", targets: ["ShadTools"])],
    targets: [
        .executableTarget(name: "ShadTools"),
        .testTarget(name: "ShadToolsTests", dependencies: ["ShadTools"])
    ]
)

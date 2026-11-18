// swift-tools-version: 6.2
import PackageDescription
import Foundation

// The staging script supplies verified source trees for every target.
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let webp = project.appendingPathComponent("libwebp-xcode")
// Bundle resources are staged from the verified upstream app by the packager.
let appResourcePaths = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("macshot").path))?
    .filter { $0.hasSuffix(".lproj") || $0.hasSuffix(".xcassets") || $0.hasSuffix(".plist") || $0.hasSuffix(".entitlements") } ?? []

let cSources = ["libwebp/src", "libwebp/sharpyuv"].flatMap { subdirectory in
    (FileManager.default.subpaths(atPath: webp.appendingPathComponent(subdirectory).path) ?? [])
        .filter { $0.hasSuffix(".c") }.map { subdirectory + "/" + $0 }
}.sorted()

let package = Package(
    name: "EmbeddedMacShot",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "libwebp", path: "libwebp-xcode",
                sources: cSources, publicHeadersPath: "include",
                cSettings: [.headerSearchPath("libwebp")]),
        .target(name: "WebP", dependencies: ["libwebp"], path: "swift-webp/Sources/WebP"),
        .executableTarget(name: "macshot", dependencies: ["WebP"], path: "macshot", exclude: appResourcePaths,
                          swiftSettings: [.defaultIsolation(MainActor.self)])
    ],
    swiftLanguageModes: [.v5]
)

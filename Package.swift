// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Each row is an edition ID, executable product, feature directory, and app display name.
let catalogue = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Packaging/Editions.tsv")
let editions = try String(contentsOf: catalogue, encoding: .utf8).split(separator: "\n").map { row in
    let fields = row.split(separator: "\t").map(String.init)
    precondition(fields.count == 4, "Invalid Packaging/Editions.tsv row")
    return (id: fields[0], product: fields[1], feature: fields[2])
}
precondition(editions.filter { $0.id == "suite" }.count == 1 &&
             Set(editions.map(\.id)).count == editions.count &&
             Set(editions.map(\.product)).count == editions.count &&
             Set(editions.map(\.feature)).count == editions.count, "Duplicate or missing edition in catalogue")
let features = editions.filter { $0.id != "suite" }
let featureTargets = features.map { "Shad" + $0.feature + "Feature" }
let targets: [Target] = [
    .target(name: "ShadCore"),
    .target(name: "ShadColorValues"),
    .target(name: "ShadFilePreview"),
    .target(name: "ShadShell", dependencies: ["ShadCore"]),
] + features.map { edition in
    var shared: [Target.Dependency] = ["ShadCore"]
    if ["color", "clipboard"].contains(edition.id) { shared.append("ShadColorValues") }
    if ["search", "clipboard"].contains(edition.id) { shared.append("ShadFilePreview") }
    return .target(name: "Shad" + edition.feature + "Feature",
                   dependencies: shared,
                   path: "Sources/Features/" + edition.feature)
} + editions.map { edition in
    let selected = edition.id == "suite" ? featureTargets : ["Shad" + edition.feature + "Feature"]
    return .executableTarget(name: edition.product,
                             dependencies: ["ShadShell"] + selected.map { .target(name: $0) },
                             path: "Sources/Products/" + edition.product)
} + [
    .testTarget(name: "ShadToolsTests",
                dependencies: ["ShadCore", "ShadColorValues", "ShadShell"] + featureTargets.map { .target(name: $0) }),
]

let package = Package(
    name: "ShadTools", platforms: [.macOS(.v13)],
    products: editions.map { .executable(name: $0.product, targets: [$0.product]) },
    targets: targets
)

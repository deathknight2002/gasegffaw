// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RitualCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RitualCore", targets: ["RitualCore"]),
    ],
    targets: [
        .target(
            name: "RitualCore",
            path: "Sources/RitualCore"
        ),
        .testTarget(
            name: "RitualCoreTests",
            dependencies: ["RitualCore"],
            path: "Tests/RitualCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)

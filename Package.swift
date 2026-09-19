// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Omil",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "OmilCore", targets: ["OmilCore"]),
        .executable(name: "omil-eval", targets: ["OmilEval"]),
    ],
    targets: [
        .target(
            name: "OmilCore",
            path: "Sources/OmilCore"
        ),
        .executableTarget(
            name: "OmilEval",
            dependencies: ["OmilCore"],
            path: "Sources/OmilEval"
        ),
        .testTarget(
            name: "OmilCoreTests",
            dependencies: ["OmilCore"],
            path: "Tests/OmilCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)

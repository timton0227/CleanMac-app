// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanCore", targets: ["CleanCore"]),
        .executable(name: "CleanMac", targets: ["CleanMac"]),
    ],
    targets: [
        .target(
            name: "CleanCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CleanMac",
            dependencies: ["CleanCore"]
        ),
        .executableTarget(
            name: "CleanHelper",
            dependencies: ["CleanCore"]
        ),
        .testTarget(
            name: "CleanCoreTests",
            dependencies: ["CleanCore"]
        ),
    ]
)

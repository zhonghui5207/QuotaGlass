// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaGlass",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QuotaGlass", targets: ["QuotaGlass"])
    ],
    targets: [
        .executableTarget(
            name: "QuotaGlass",
            path: "Sources/QuotaGlass",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "QuotaGlassTests",
            dependencies: ["QuotaGlass"],
            path: "Tests/QuotaGlassTests"
        )
    ]
)

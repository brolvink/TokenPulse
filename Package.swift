// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenPulse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenPulse", targets: ["TokenPulse"]),
        .library(name: "TokenPulseCore", targets: ["TokenPulseCore"])
    ],
    targets: [
        .target(
            name: "TokenPulseCore",
            path: "Sources/TokenPulseCore"
        ),
        .executableTarget(
            name: "TokenPulse",
            dependencies: ["TokenPulseCore"],
            path: "Sources/TokenPulse"
        ),
        .testTarget(
            name: "TokenPulseTests",
            dependencies: ["TokenPulseCore"],
            path: "Tests/TokenPulseTests"
        )
    ]
)

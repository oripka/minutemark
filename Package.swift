// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MinuteMark",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "MinuteMark", targets: ["MinuteMarkApp"])
    ],
    targets: [
        .target(name: "MinuteMarkCore"),
        .executableTarget(
            name: "MinuteMarkApp",
            dependencies: ["MinuteMarkCore"]
        ),
        .testTarget(
            name: "MinuteMarkCoreTests",
            dependencies: ["MinuteMarkCore"]
        )
    ]
)

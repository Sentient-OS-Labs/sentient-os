// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SentientComputerUse",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SentientComputerUseCore", targets: ["SentientComputerUseCore"]),
        .executable(name: "SentientComputerUseService", targets: ["SentientComputerUseService"])
    ],
    targets: [
        .target(name: "SentientComputerUseCore"),
        .executableTarget(
            name: "SentientComputerUseService",
            dependencies: ["SentientComputerUseCore"]
        ),
        .testTarget(
            name: "SentientComputerUseCoreTests",
            dependencies: ["SentientComputerUseCore", "SentientComputerUseService"]
        )
    ]
)

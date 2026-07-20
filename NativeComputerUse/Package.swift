// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SentientComputerUse",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SentientComputerUseCore", targets: ["SentientComputerUseCore"])
    ],
    targets: [
        .target(name: "SentientComputerUseCore"),
        .testTarget(
            name: "SentientComputerUseCoreTests",
            dependencies: ["SentientComputerUseCore"]
        )
    ]
)

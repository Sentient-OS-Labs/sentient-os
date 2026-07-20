// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SentientComputerUse",
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

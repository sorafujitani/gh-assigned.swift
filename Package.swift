// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gh-assigned",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AssignedCore", targets: ["AssignedCore"]),
        .library(name: "AssignedTerminal", targets: ["AssignedTerminal"]),
        .library(name: "AssignedCLI", targets: ["AssignedCLI"]),
        .executable(name: "gh-assigned", targets: ["gh-assigned"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "AssignedCore"),
        .target(
            name: "AssignedTerminalC",
            path: "CSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AssignedTerminal",
            dependencies: ["AssignedCore", "AssignedTerminalC"],
            path: "Sources/AssignedTerminal"
        ),
        .target(
            name: "AssignedCLI",
            dependencies: [
                "AssignedCore",
                "AssignedTerminal",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "gh-assigned", dependencies: ["AssignedCLI"]),
        .testTarget(
            name: "AssignedTests",
            dependencies: ["AssignedCore", "AssignedTerminal", "AssignedCLI"]
        ),
    ]
)

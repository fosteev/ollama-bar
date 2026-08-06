// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ollama-bar",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OllamaBarCore", targets: ["OllamaBarCore"]),
        .library(name: "OllamaBarInfrastructure", targets: ["OllamaBarInfrastructure"]),
        .executable(name: "ollama-bar-cli", targets: ["OllamaBarCLI"]),
    ],
    targets: [
        .target(
            name: "OllamaBarCore",
            path: "Sources/Core"
        ),
        .target(
            name: "OllamaBarInfrastructure",
            dependencies: ["OllamaBarCore"],
            path: "Sources/Infrastructure"
        ),
        .executableTarget(
            name: "OllamaBarCLI",
            dependencies: ["OllamaBarCore", "OllamaBarInfrastructure"],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["OllamaBarCore"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "InfrastructureTests",
            dependencies: ["OllamaBarCore", "OllamaBarInfrastructure"],
            path: "Tests/InfrastructureTests"
        ),
    ]
)

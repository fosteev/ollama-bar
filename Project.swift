import ProjectDescription

/// Tuist owns the `.app` bundle; the same sources also build as a plain SPM package
/// (`swift build` / `swift test`) for the headless core and the CLI — see docs/PLAN.md.
private let deploymentTargets: DeploymentTargets = .macOS("15.0")

private let layerSettings: Settings = .settings(
    base: ["SWIFT_STRICT_CONCURRENCY": "complete"]
)

let project = Project(
    name: "OllamaBar",
    options: .options(
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "CODE_SIGN_IDENTITY": "-",
            "CODE_SIGN_STYLE": "Manual",
            "ENABLE_DEBUG_DYLIB": "YES",
        ]
    ),
    targets: [
        // MARK: - Core (domain, no I/O)
        .target(
            name: "OllamaBarCore",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.fosteev.ollamabar.core",
            deploymentTargets: deploymentTargets,
            sources: ["Sources/Core/**"],
            settings: layerSettings
        ),

        // MARK: - Infrastructure (HTTP, log tailing, storage)
        .target(
            name: "OllamaBarInfrastructure",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.fosteev.ollamabar.infrastructure",
            deploymentTargets: deploymentTargets,
            sources: ["Sources/Infrastructure/**"],
            dependencies: [.target(name: "OllamaBarCore")],
            settings: layerSettings
        ),

        // MARK: - Menu bar app
        .target(
            name: "OllamaBar",
            destinations: .macOS,
            product: .app,
            bundleId: "com.fosteev.ollamabar",
            deploymentTargets: deploymentTargets,
            infoPlist: .file(path: "Sources/App/Info.plist"),
            sources: ["Sources/App/**"],
            dependencies: [
                .target(name: "OllamaBarCore"),
                .target(name: "OllamaBarInfrastructure"),
            ]
        ),

        // MARK: - Tests
        .target(
            name: "CoreTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.fosteev.ollamabar.core.tests",
            deploymentTargets: deploymentTargets,
            sources: ["Tests/CoreTests/**"],
            dependencies: [.target(name: "OllamaBarCore")]
        ),
        .target(
            name: "InfrastructureTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.fosteev.ollamabar.infrastructure.tests",
            deploymentTargets: deploymentTargets,
            sources: ["Tests/InfrastructureTests/**"],
            dependencies: [
                .target(name: "OllamaBarCore"),
                .target(name: "OllamaBarInfrastructure"),
            ]
        ),
    ],
    schemes: [
        .scheme(
            name: "OllamaBar",
            shared: true,
            buildAction: .buildAction(targets: ["OllamaBar"]),
            testAction: .targets(["CoreTests", "InfrastructureTests"]),
            runAction: .runAction(executable: "OllamaBar")
        )
    ]
)

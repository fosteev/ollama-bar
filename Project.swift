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
            // One place for the version. `Info.plist` reads it back through the build setting.
            "MARKETING_VERSION": "0.1.1",
            "CURRENT_PROJECT_VERSION": "2",
        ],
        configurations: [
            // The debug dylib speeds up incremental builds and has no business in a shipped app.
            .debug(name: "Debug", settings: ["ENABLE_DEBUG_DYLIB": "YES"]),
            .release(name: "Release", settings: [
                "ENABLE_DEBUG_DYLIB": "NO",
                // Notarization refuses a build without it, and it costs an ad-hoc build nothing —
                // so Release carries it either way and the signed and unsigned artifacts differ
                // in one thing only, the signature.
                "ENABLE_HARDENED_RUNTIME": "YES",
                // Xcode otherwise injects `com.apple.security.get-task-allow` — the entitlement
                // that lets a debugger attach — into Release too, and the notary service rejects
                // any binary carrying it. Nothing catches this until the day you first notarize.
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            ]),
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
            resources: ["Sources/App/Resources/**"],
            entitlements: .file(path: "Sources/App/OllamaBar.entitlements"),
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

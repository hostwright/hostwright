// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "hostwright",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "hostwright", targets: ["HostwrightCLI"]),
        .executable(name: "hostwrightd", targets: ["HostwrightDaemon"]),
        .library(name: "HostwrightCore", targets: ["HostwrightCore"]),
        .library(name: "HostwrightManifest", targets: ["HostwrightManifest"]),
        .library(name: "HostwrightRuntime", targets: ["HostwrightRuntime"]),
        .library(name: "HostwrightState", targets: ["HostwrightState"]),
        .library(name: "HostwrightReconciler", targets: ["HostwrightReconciler"]),
        .library(name: "HostwrightDaemonCore", targets: ["HostwrightDaemonCore"]),
        .library(name: "HostwrightHealth", targets: ["HostwrightHealth"]),
        .library(name: "HostwrightImport", targets: ["HostwrightImport"]),
        .library(name: "HostwrightNetworking", targets: ["HostwrightNetworking"]),
        .library(name: "HostwrightObservability", targets: ["HostwrightObservability"]),
        .library(name: "HostwrightPolicy", targets: ["HostwrightPolicy"]),
        .library(name: "HostwrightSecrets", targets: ["HostwrightSecrets"])
    ],
    targets: [
        .executableTarget(
            name: "HostwrightCLI",
            dependencies: [
                "HostwrightCore",
                "HostwrightHealth",
                "HostwrightImport",
                "HostwrightManifest",
                "HostwrightPolicy",
                "HostwrightReconciler",
                "HostwrightRuntime",
                "HostwrightSecrets",
                "HostwrightState"
            ]
        ),
        .executableTarget(
            name: "HostwrightDaemon",
            dependencies: [
                "HostwrightCore",
                "HostwrightDaemonCore",
                "HostwrightRuntime"
            ]
        ),
        .target(name: "HostwrightCore"),
        .target(
            name: "HostwrightManifest",
            dependencies: [
                "HostwrightCore",
                "HostwrightSecrets"
            ]
        ),
        .target(
            name: "HostwrightRuntime",
            dependencies: [
                "HostwrightCore",
                "HostwrightSecrets"
            ]
        ),
        .target(
            name: "HostwrightState",
            dependencies: [
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightRuntime"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "HostwrightReconciler",
            dependencies: [
                "HostwrightCore",
                "HostwrightHealth",
                "HostwrightManifest",
                "HostwrightNetworking",
                "HostwrightPolicy",
                "HostwrightRuntime",
                "HostwrightSecrets",
                "HostwrightState"
            ]
        ),
        .target(
            name: "HostwrightDaemonCore",
            dependencies: [
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightReconciler",
                "HostwrightRuntime",
                "HostwrightState"
            ]
        ),
        .target(
            name: "HostwrightHealth",
            dependencies: ["HostwrightCore"],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "HostwrightImport",
            dependencies: [
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightPolicy"
            ]
        ),
        .target(
            name: "HostwrightNetworking",
            dependencies: ["HostwrightCore"]
        ),
        .target(
            name: "HostwrightObservability",
            dependencies: ["HostwrightCore"]
        ),
        .target(
            name: "HostwrightPolicy",
            dependencies: [
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightNetworking",
                "HostwrightRuntime"
            ]
        ),
        .target(
            name: "HostwrightSecrets",
            linkerSettings: [
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "HostwrightTestSupport",
            dependencies: [
                "HostwrightCore",
                "HostwrightRuntime",
                "HostwrightSecrets"
            ],
            path: "Tests/HostwrightTestSupport"
        ),
        .testTarget(
            name: "HostwrightCoreTests",
            dependencies: ["HostwrightCore"]
        ),
        .testTarget(
            name: "HostwrightManifestTests",
            dependencies: ["HostwrightManifest"]
        ),
        .testTarget(
            name: "HostwrightRuntimeTests",
            dependencies: [
                "HostwrightRuntime",
                "HostwrightTestSupport"
            ],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "HostwrightStateTests",
            dependencies: [
                "HostwrightManifest",
                "HostwrightRuntime",
                "HostwrightState"
            ]
        ),
        .testTarget(
            name: "HostwrightReconcilerTests",
            dependencies: [
                "HostwrightHealth",
                "HostwrightPolicy",
                "HostwrightReconciler"
            ]
        ),
        .testTarget(
            name: "HostwrightDaemonTests",
            dependencies: [
                "HostwrightDaemonCore",
                "HostwrightManifest",
                "HostwrightRuntime",
                "HostwrightState"
            ]
        ),
        .testTarget(
            name: "HostwrightCLITests",
            dependencies: [
                "HostwrightCLI",
                "HostwrightManifest",
                "HostwrightReconciler",
                "HostwrightRuntime",
                "HostwrightSecrets",
                "HostwrightState",
                "HostwrightTestSupport"
            ]
        ),
        .testTarget(
            name: "HostwrightHealthTests",
            dependencies: ["HostwrightHealth"],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "HostwrightImportTests",
            dependencies: [
                "HostwrightImport",
                "HostwrightManifest"
            ]
        ),
        .testTarget(
            name: "HostwrightNetworkingTests",
            dependencies: ["HostwrightNetworking"]
        ),
        .testTarget(
            name: "HostwrightObservabilityTests",
            dependencies: ["HostwrightObservability"]
        ),
        .testTarget(
            name: "HostwrightPolicyTests",
            dependencies: [
                "HostwrightManifest",
                "HostwrightPolicy",
                "HostwrightRuntime"
            ]
        ),
        .testTarget(
            name: "HostwrightSecretsTests",
            dependencies: [
                "HostwrightSecrets",
                "HostwrightTestSupport"
            ]
        )
    ]
)

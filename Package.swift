// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "hostwright",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "hostwright", targets: ["HostwrightCommand"]),
        .executable(name: "hostwright-control", targets: ["HostwrightControlTool"]),
        .executable(
            name: "hostwright-containerization-helper",
            targets: ["HostwrightContainerizationHelper"]
        ),
        .executable(name: "hostwrightd", targets: ["HostwrightDaemon"]),
        .executable(name: "hostwright-dist", targets: ["HostwrightDistributionTool"]),
        .executable(
            name: "hostwright-runtime-conformance",
            targets: ["HostwrightRuntimeConformanceTool"]
        ),
        .library(name: "HostwrightCore", targets: ["HostwrightCore"]),
        .library(name: "HostwrightControl", targets: ["HostwrightControl"]),
        .library(name: "HostwrightManifest", targets: ["HostwrightManifest"]),
        .library(name: "HostwrightRuntime", targets: ["HostwrightRuntime"]),
        .library(name: "HostwrightState", targets: ["HostwrightState"]),
        .library(name: "HostwrightReconciler", targets: ["HostwrightReconciler"]),
        .library(name: "HostwrightDaemonCore", targets: ["HostwrightDaemonCore"]),
        .library(name: "HostwrightHealth", targets: ["HostwrightHealth"]),
        .library(name: "HostwrightImport", targets: ["HostwrightImport"]),
        .library(name: "HostwrightExtensions", targets: ["HostwrightExtensions"]),
        .library(name: "HostwrightNetworking", targets: ["HostwrightNetworking"]),
        .library(name: "HostwrightObservability", targets: ["HostwrightObservability"]),
        .library(name: "HostwrightPolicy", targets: ["HostwrightPolicy"]),
        .library(name: "HostwrightSecrets", targets: ["HostwrightSecrets"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/containerization.git",
            exact: "0.35.0"
        ),
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "6.2.2"
        )
    ],
    targets: [
        .target(
            name: "HostwrightCLI",
            dependencies: [
                "HostwrightCore",
                "HostwrightExtensions",
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
            name: "HostwrightCommand",
            dependencies: ["HostwrightCLI"]
        ),
        .executableTarget(
            name: "HostwrightControlTool",
            dependencies: ["HostwrightControl"]
        ),
        .executableTarget(
            name: "HostwrightContainerizationHelper",
            dependencies: [
                "HostwrightCore",
                "HostwrightRuntime",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization")
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
        .executableTarget(
            name: "HostwrightDistributionTool",
            dependencies: ["HostwrightDistribution"]
        ),
        .executableTarget(
            name: "HostwrightRuntimeConformanceTool",
            dependencies: [
                "HostwrightCLI",
                "HostwrightCore",
                "HostwrightRuntime",
                "HostwrightState"
            ]
        ),
        .target(name: "HostwrightCore"),
        .target(
            name: "HostwrightControl",
            dependencies: [
                "HostwrightCLI",
                "HostwrightCore"
            ]
        ),
        .target(
            name: "HostwrightDistribution",
            dependencies: [
                "HostwrightCore",
                "HostwrightState"
            ]
        ),
        .target(
            name: "HostwrightExtensions",
            dependencies: [
                "HostwrightCore",
                "HostwrightPolicy"
            ]
        ),
        .target(
            name: "HostwrightManifest",
            dependencies: [
                "HostwrightCore",
                "HostwrightSecrets",
                .product(name: "Yams", package: "Yams")
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
                "HostwrightRuntime",
                "HostwrightSQLiteSupport"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "HostwrightSQLiteSupport",
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
            name: "HostwrightControlTests",
            dependencies: [
                "HostwrightCLI",
                "HostwrightControl",
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightState",
                "HostwrightTestSupport"
            ]
        ),
        .testTarget(
            name: "HostwrightCoreTests",
            dependencies: ["HostwrightCore"],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "HostwrightDistributionTests",
            dependencies: [
                "HostwrightDistribution",
                "HostwrightState"
            ]
        ),
        .testTarget(
            name: "HostwrightExtensionsTests",
            dependencies: [
                "HostwrightCore",
                "HostwrightExtensions",
                "HostwrightPolicy"
            ],
            resources: [
                .process("Fixtures")
            ]
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
            name: "HostwrightContainerizationHelperTests",
            dependencies: [
                "HostwrightContainerizationHelper",
                "HostwrightRuntime"
            ]
        ),
        .testTarget(
            name: "HostwrightRuntimeConformanceToolTests",
            dependencies: [
                "HostwrightCLI",
                "HostwrightCore",
                "HostwrightRuntime",
                "HostwrightRuntimeConformanceTool",
                "HostwrightState"
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

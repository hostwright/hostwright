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
        .executable(
            name: "hostwright-storage-helper",
            targets: ["HostwrightStorageProviderHelper"]
        ),
        .executable(
            name: "hostwright-network-helper",
            targets: ["HostwrightNetworkHelper"]
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
        .library(name: "HostwrightRegistry", targets: ["HostwrightRegistry"]),
        .library(name: "HostwrightSecrets", targets: ["HostwrightSecrets"]),
        .library(name: "HostwrightStorage", targets: ["HostwrightStorage"]),
        .library(
            name: "HostwrightStorageHelper",
            targets: ["HostwrightStorageHelper"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/containerization.git",
            exact: "0.35.0"
        ),
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "6.2.2"
        ),
        .package(
            url: "https://github.com/apple/swift-certificates.git",
            exact: "1.19.3"
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
                "HostwrightNetworkHelperCore",
                "HostwrightNetworking",
                "HostwrightPolicy",
                "HostwrightReconciler",
                "HostwrightRegistry",
                "HostwrightRuntime",
                "HostwrightSecrets",
                "HostwrightState",
                "HostwrightStorage"
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
                "HostwrightNetworking",
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
        .executableTarget(
            name: "HostwrightStorageProviderHelper",
            dependencies: [
                "HostwrightStorage",
                "HostwrightStorageHelper"
            ]
        ),
        .executableTarget(
            name: "HostwrightNetworkHelper",
            dependencies: ["HostwrightNetworkHelperCore"]
        ),
        .target(
            name: "HostwrightNetworkHelperCore",
            dependencies: [
                "HostwrightNetworking",
                "HostwrightRuntime",
                .product(name: "X509", package: "swift-certificates")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(name: "HostwrightCore"),
        .target(
            name: "HostwrightControl",
            dependencies: [
                "HostwrightCLI",
                "HostwrightCore",
                "HostwrightRegistry",
                "HostwrightRuntime"
            ]
        ),
        .target(
            name: "HostwrightDistribution",
            dependencies: [
                "HostwrightCore",
                "HostwrightState",
                "HostwrightStorage"
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
                "HostwrightNetworking",
                "HostwrightSecrets",
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .target(
            name: "HostwrightRuntime",
            dependencies: [
                "HostwrightCore",
                "HostwrightNetworking",
                "HostwrightSecrets"
            ]
        ),
        .target(
            name: "HostwrightState",
            dependencies: [
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightRegistry",
                "HostwrightRuntime",
                "HostwrightStorage",
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
                "HostwrightState",
                "HostwrightStorage"
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
            name: "HostwrightRegistry",
            dependencies: [
                "HostwrightCore",
                "HostwrightSecrets"
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
            name: "HostwrightStorage",
            dependencies: [
                "HostwrightCore",
                "HostwrightRuntime",
                "HostwrightSecrets"
            ]
        ),
        .target(
            name: "HostwrightStorageHelper",
            dependencies: ["HostwrightStorage"],
            linkerSettings: [
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
                "HostwrightState",
                "HostwrightStorage"
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
                "HostwrightCore",
                "HostwrightRuntime",
                .product(name: "Containerization", package: "containerization")
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
                "HostwrightRegistry",
                "HostwrightRuntime",
                "HostwrightState",
                "HostwrightStorage"
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
                "HostwrightRegistry",
                "HostwrightRuntime",
                "HostwrightSecrets",
                "HostwrightState",
                "HostwrightStorage",
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
            name: "HostwrightNetworkHelperTests",
            dependencies: [
                "HostwrightNetworkHelperCore",
                "HostwrightRuntime"
            ]
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
            name: "HostwrightRegistryTests",
            dependencies: [
                "HostwrightRegistry",
                "HostwrightTestSupport"
            ]
        ),
        .testTarget(
            name: "HostwrightSecretsTests",
            dependencies: [
                "HostwrightSecrets",
                "HostwrightTestSupport"
            ]
        ),
        .testTarget(
            name: "HostwrightStorageTests",
            dependencies: [
                "HostwrightStorage",
                "HostwrightTestSupport"
            ]
        )
    ]
)

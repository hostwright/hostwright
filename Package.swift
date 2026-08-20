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
        .executable(
            name: "hostwright-network-provider-worker",
            targets: ["HostwrightNetworkProviderWorker"]
        ),
        .executable(
            name: "hostwright-wasi-provider-worker",
            targets: ["HostwrightWASIProviderWorker"]
        ),
        .executable(
            name: "hostwright-wasi-provider-qualification",
            targets: ["HostwrightWASIProviderQualificationTool"]
        ),
        .executable(
            name: "hostwright-wasi-reference-provider",
            targets: ["HostwrightWASIReferenceProvider"]
        ),
        .executable(
            name: "hostwright-wasi-adversarial-provider",
            targets: ["HostwrightWASIAdversarialProvider"]
        ),
        .executable(
            name: "hostwright-xpc-provider-service",
            targets: ["HostwrightXPCProviderService"]
        ),
        .executable(
            name: "hostwright-accelerator-service",
            targets: ["HostwrightAcceleratorService"]
        ),
        .executable(
            name: "hostwright-xpc-provider-qualification",
            targets: ["HostwrightXPCProviderQualificationTool"]
        ),
        .executable(
            name: "hostwright-tunnel-qualification",
            targets: ["HostwrightTunnelQualificationTool"]
        ),
        .executable(
            name: "hostwright-control-security-qualification",
            targets: ["HostwrightControlSecurityQualificationTool"]
        ),
        .executable(
            name: "hostwright-audit-qualification",
            targets: ["HostwrightAuditQualificationTool"]
        ),
        .executable(
            name: "hostwright-rbac-qualification",
            targets: ["HostwrightRBACQualificationTool"]
        ),
        .executable(
            name: "hostwright-admission-qualification",
            targets: ["HostwrightAdmissionQualificationTool"]
        ),
        .executable(
            name: "hostwright-profile-qualification",
            targets: ["HostwrightProfileQualificationTool"]
        ),
        .executable(
            name: "hostwright-stream-qualification",
            targets: ["HostwrightStreamQualificationTool"]
        ),
        .executable(name: "hostwrightd", targets: ["HostwrightDaemon"]),
        .executable(
            name: "hostwright-docker-proxy",
            targets: ["HostwrightDockerProxy"]
        ),
        .executable(name: "hostwright-dist", targets: ["HostwrightDistributionTool"]),
        .executable(
            name: "hostwright-runtime-conformance",
            targets: ["HostwrightRuntimeConformanceTool"]
        ),
        .library(name: "HostwrightCore", targets: ["HostwrightCore"]),
        .library(name: "HostwrightControlPlane", targets: ["HostwrightControlPlane"]),
        .library(name: "HostwrightControlSecurity", targets: ["HostwrightControlSecurity"]),
        .library(name: "HostwrightControl", targets: ["HostwrightControl"]),
        .library(
            name: "HostwrightCommandTransport",
            targets: ["HostwrightCommandTransport"]
        ),
        .library(
            name: "HostwrightControlTransport",
            targets: ["HostwrightControlTransport"]
        ),
        .library(name: "HostwrightDockerEngine", targets: ["HostwrightDockerEngine"]),
        .library(name: "HostwrightManifest", targets: ["HostwrightManifest"]),
        .library(name: "HostwrightRuntime", targets: ["HostwrightRuntime"]),
        .library(name: "HostwrightState", targets: ["HostwrightState"]),
        .library(name: "HostwrightReconciler", targets: ["HostwrightReconciler"]),
        .library(name: "HostwrightScheduler", targets: ["HostwrightScheduler"]),
        .library(name: "HostwrightDaemonCore", targets: ["HostwrightDaemonCore"]),
        .library(name: "HostwrightHealth", targets: ["HostwrightHealth"]),
        .library(name: "HostwrightAccelerator", targets: ["HostwrightAccelerator"]),
        .library(
            name: "HostwrightAcceleratorXPC",
            targets: ["HostwrightAcceleratorXPC"]
        ),
        .library(name: "HostwrightImport", targets: ["HostwrightImport"]),
        .library(name: "HostwrightExtensions", targets: ["HostwrightExtensions"]),
        .library(name: "HostwrightNetworking", targets: ["HostwrightNetworking"]),
        .library(name: "HostwrightNetworkProviders", targets: ["HostwrightNetworkProviders"]),
        .library(name: "HostwrightWASIProviderSDK", targets: ["HostwrightWASIProviderSDK"]),
        .library(name: "HostwrightWASIProviderRuntime", targets: ["HostwrightWASIProviderRuntime"]),
        .library(name: "HostwrightXPCProvider", targets: ["HostwrightXPCProvider"]),
        .library(name: "HostwrightObservability", targets: ["HostwrightObservability"]),
        .library(name: "HostwrightPolicy", targets: ["HostwrightPolicy"]),
        .library(name: "HostwrightRegistry", targets: ["HostwrightRegistry"]),
        .library(name: "HostwrightSecrets", targets: ["HostwrightSecrets"]),
        .library(name: "HostwrightStorage", targets: ["HostwrightStorage"]),
        .library(name: "HostwrightCluster", targets: ["HostwrightCluster"]),
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
        ),
        .package(
            url: "https://github.com/swiftwasm/WasmKit.git",
            exact: "0.3.1"
        )
    ],
    targets: [
        .target(
            name: "HostwrightCLI",
            dependencies: [
                "HostwrightControlSecurity",
                "HostwrightCore",
                "HostwrightDaemonCore",
                "HostwrightExtensions",
                "HostwrightHealth",
                "HostwrightImport",
                "HostwrightManifest",
                "HostwrightNetworkHelperCore",
                "HostwrightNetworking",
                "HostwrightObservability",
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
            dependencies: ["HostwrightCommandTransport"]
        ),
        .executableTarget(
            name: "HostwrightControlTool",
            dependencies: [
                "HostwrightControl",
                "HostwrightControlPlane",
                "HostwrightCommandTransport",
                "HostwrightControlTransport"
            ]
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
                "HostwrightCLI",
                "HostwrightCommandTransport",
                "HostwrightControl",
                "HostwrightControlPlane",
                "HostwrightControlSecurity",
                "HostwrightControlTransport",
                "HostwrightCore",
                "HostwrightDaemonCore",
                "HostwrightExtensions",
                "HostwrightHealth",
                "HostwrightObservability",
                "HostwrightPolicy",
                "HostwrightRegistry",
                "HostwrightRuntime",
                "HostwrightScheduler",
                "HostwrightState"
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
                "HostwrightControlPlane",
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightRuntime",
                "HostwrightState"
            ]
        ),
        // Qualification-only continuity tooling is intentionally not exposed as a product.
        .executableTarget(
            name: "HostwrightPhase09QualificationTool",
            dependencies: ["HostwrightCore"],
            path: "Qualification/HostwrightPhase09QualificationTool"
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
            dependencies: [
                "HostwrightNetworkHelperCore",
                "HostwrightState"
            ]
        ),
        .target(
            name: "HostwrightNetworkHelperCore",
            dependencies: [
                "HostwrightNetworking",
                "HostwrightNetworkProviders",
                "HostwrightRuntime",
                .product(name: "X509", package: "swift-certificates")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(name: "HostwrightCore"),
        .target(
            name: "HostwrightControlPlane",
            dependencies: ["HostwrightCore"]
        ),
        .target(
            name: "HostwrightControlSecurity",
            dependencies: ["HostwrightControlPlane", "HostwrightCore"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("bsm"),
            ]
        ),
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
            name: "HostwrightCommandTransport",
            dependencies: [
                "HostwrightCLI",
                "HostwrightControlPlane",
                "HostwrightControlSecurity",
                "HostwrightControlTransport",
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightRuntime",
                "HostwrightState"
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "HostwrightControlTransport",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightControlSecurity",
                "HostwrightCore",
                "HostwrightState"
            ]
        ),
        .target(
            name: "HostwrightDockerEngine",
            dependencies: [
                "HostwrightCommandTransport",
                "HostwrightControlPlane",
                "HostwrightControlSecurity",
                "HostwrightControlTransport",
                "HostwrightCore"
            ]
        ),
        .executableTarget(
            name: "HostwrightDockerProxy",
            dependencies: ["HostwrightDockerEngine"]
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
                "HostwrightControlPlane",
                "HostwrightCore",
                "HostwrightNetworkProviders",
                "HostwrightPolicy",
                "HostwrightRegistry",
                "HostwrightState",
                "HostwrightWASIProviderRuntime",
                "HostwrightXPCProvider"
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
                "HostwrightControlPlane",
                "HostwrightControlSecurity",
                "HostwrightAccelerator",
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightObservability",
                "HostwrightRegistry",
                "HostwrightRuntime",
                "HostwrightScheduler",
                "HostwrightStorage",
                "HostwrightSQLiteSupport"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security")
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
                "HostwrightObservability",
                "HostwrightPolicy",
                "HostwrightRuntime",
                "HostwrightScheduler",
                "HostwrightSecrets",
                "HostwrightState",
                "HostwrightStorage"
            ]
        ),
        .target(name: "HostwrightScheduler"),
        .target(name: "HostwrightAccelerator"),
        .target(
            name: "HostwrightAcceleratorXPC",
            dependencies: ["HostwrightAccelerator", "HostwrightCore"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "HostwrightDaemonCore",
            dependencies: [
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightObservability",
                "HostwrightPolicy",
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
            name: "HostwrightNetworkProviders",
            dependencies: [
                "HostwrightCore",
                .product(name: "WasmKit", package: "WasmKit")
            ],
            exclude: ["Worker"]
        ),
        .executableTarget(
            name: "HostwrightNetworkProviderWorker",
            dependencies: [
                "HostwrightNetworkProviders",
                .product(name: "WasmKit", package: "WasmKit")
            ],
            path: "Sources/HostwrightNetworkProviders/Worker"
        ),
        .target(
            name: "HostwrightWASIProviderSDK"
        ),
        .target(
            name: "HostwrightWASIProviderRuntime",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightCore",
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
                .product(name: "WASI", package: "WasmKit")
            ]
        ),
        .executableTarget(
            name: "HostwrightWASIProviderWorker",
            dependencies: ["HostwrightControlPlane", "HostwrightWASIProviderRuntime"]
        ),
        .executableTarget(
            name: "HostwrightWASIProviderQualificationTool",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightCore",
                "HostwrightWASIProviderRuntime"
            ]
        ),
        .executableTarget(
            name: "HostwrightWASIReferenceProvider",
            dependencies: ["HostwrightWASIProviderSDK"]
        ),
        .executableTarget(
            name: "HostwrightWASIAdversarialProvider",
            dependencies: ["HostwrightWASIProviderSDK"]
        ),
        .target(
            name: "HostwrightXPCProvider",
            dependencies: ["HostwrightControlPlane"]
        ),
        .executableTarget(
            name: "HostwrightXPCProviderService",
            dependencies: ["HostwrightXPCProvider"]
        ),
        .executableTarget(
            name: "HostwrightAcceleratorService",
            dependencies: [
                "HostwrightAcceleratorXPC",
                "HostwrightCore",
                "HostwrightState"
            ]
        ),
        .executableTarget(
            name: "HostwrightXPCProviderQualificationTool",
            dependencies: ["HostwrightControlPlane", "HostwrightXPCProvider"]
        ),
        .target(
            name: "HostwrightObservability",
            dependencies: ["HostwrightCore"]
        ),
        .target(
            name: "HostwrightPolicy",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightCore",
                "HostwrightManifest",
                "HostwrightNetworking",
                "HostwrightRuntime",
                "HostwrightState"
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
            name: "HostwrightCluster",
            dependencies: [
                "HostwrightCore",
                "HostwrightControlPlane",
                .product(name: "X509", package: "swift-certificates")
            ],
            linkerSettings: [
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security")
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
        .executableTarget(
            name: "HostwrightTunnelQualificationTool",
            dependencies: [
                "HostwrightManifest",
                "HostwrightNetworkHelperCore",
                "HostwrightState"
            ],
            path: "Tests/HostwrightTunnelQualificationTool"
        ),
        .executableTarget(
            name: "HostwrightControlSecurityQualificationTool",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightControlSecurity",
                "HostwrightState"
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("bsm"),
            ]
        ),
        .executableTarget(
            name: "HostwrightAuditQualificationTool",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightCore",
                "HostwrightState"
            ]
        ),
        .executableTarget(
            name: "HostwrightRBACQualificationTool",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightPolicy",
                "HostwrightState"
            ]
        ),
        .executableTarget(
            name: "HostwrightAdmissionQualificationTool",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightPolicy",
                "HostwrightState"
            ]
        ),
        .executableTarget(
            name: "HostwrightProfileQualificationTool",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightPolicy",
                "HostwrightRuntime",
                "HostwrightState"
            ]
        ),
        .executableTarget(
            name: "HostwrightStreamQualificationTool",
            dependencies: [
                "HostwrightCommandTransport",
                "HostwrightControlPlane",
                "HostwrightControlSecurity",
                "HostwrightControlTransport",
                "HostwrightCore",
                "HostwrightState"
            ]
        ),
        .testTarget(
            name: "HostwrightControlPlaneTests",
            dependencies: ["HostwrightControlPlane"]
        ),
        .testTarget(
            name: "HostwrightControlSecurityTests",
            dependencies: ["HostwrightControlSecurity", "HostwrightControlPlane"]
        ),
        .testTarget(
            name: "HostwrightControlSecurityQualificationToolTests",
            dependencies: ["HostwrightControlSecurityQualificationTool"]
        ),
        .testTarget(
            name: "HostwrightAuditQualificationToolTests",
            dependencies: ["HostwrightAuditQualificationTool", "HostwrightCore"]
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
            name: "HostwrightCommandTransportTests",
            dependencies: [
                "HostwrightCLI",
                "HostwrightCommandTransport",
                "HostwrightControlPlane",
                "HostwrightControlTransport",
                "HostwrightCore",
                "HostwrightDaemonCore",
                "HostwrightObservability",
                "HostwrightRuntime"
            ]
        ),
        .testTarget(
            name: "HostwrightControlTransportTests",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightControlTransport"
            ]
        ),
        .testTarget(
            name: "HostwrightDockerEngineTests",
            dependencies: [
                "HostwrightCommandTransport",
                "HostwrightControlPlane",
                "HostwrightDockerEngine",
                "HostwrightControlTransport",
                "HostwrightCore"
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
                "HostwrightControlSecurity",
                "HostwrightExtensions",
                "HostwrightPolicy",
                "HostwrightRegistry",
                "HostwrightState",
                "HostwrightWASIProviderRuntime"
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
            name: "HostwrightPhase09QualificationToolTests",
            dependencies: ["HostwrightCore", "HostwrightPhase09QualificationTool"]
        ),
        .testTarget(
            name: "HostwrightStateTests",
            dependencies: [
                "HostwrightAccelerator",
                "HostwrightControlPlane",
                "HostwrightControlSecurity",
                "HostwrightManifest",
                "HostwrightObservability",
                "HostwrightRegistry",
                "HostwrightRuntime",
                "HostwrightScheduler",
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
            name: "HostwrightSchedulerTests",
            dependencies: ["HostwrightScheduler"]
        ),
        .testTarget(
            name: "HostwrightDaemonTests",
            dependencies: [
                "HostwrightCLI",
                "HostwrightCommandTransport",
                "HostwrightDaemon",
                "HostwrightDaemonCore",
                "HostwrightHealth",
                "HostwrightManifest",
                "HostwrightRuntime",
                "HostwrightScheduler",
                "HostwrightState"
            ]
        ),
        .testTarget(
            name: "HostwrightCLITests",
            dependencies: [
                "HostwrightCLI",
                "HostwrightControlPlane",
                "HostwrightDaemonCore",
                "HostwrightManifest",
                "HostwrightObservability",
                "HostwrightPolicy",
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
            name: "HostwrightAcceleratorTests",
            dependencies: ["HostwrightAccelerator"]
        ),
        .testTarget(
            name: "HostwrightAcceleratorXPCTests",
            dependencies: [
                "HostwrightAccelerator",
                "HostwrightAcceleratorXPC",
                "HostwrightCore",
                "HostwrightState"
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
            name: "HostwrightNetworkProvidersTests",
            dependencies: [
                "HostwrightNetworkProviders",
                "HostwrightNetworkProviderWorker"
            ]
        ),
        .testTarget(
            name: "HostwrightWASIProviderSDKTests",
            dependencies: ["HostwrightWASIProviderSDK"]
        ),
        .testTarget(
            name: "HostwrightWASIProviderRuntimeTests",
            dependencies: [
                "HostwrightControlPlane",
                "HostwrightWASIProviderRuntime",
                "HostwrightWASIProviderWorker"
            ]
        ),
        .testTarget(
            name: "HostwrightXPCProviderTests",
            dependencies: ["HostwrightControlPlane", "HostwrightXPCProvider"]
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
                "HostwrightControlPlane",
                "HostwrightManifest",
                "HostwrightPolicy",
                "HostwrightRuntime",
                "HostwrightState"
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
        ),
        .testTarget(
            name: "HostwrightClusterTests",
            dependencies: [
                "HostwrightCluster",
                .product(name: "X509", package: "swift-certificates")
            ],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)

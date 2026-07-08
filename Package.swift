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
        .library(name: "HostwrightNetworking", targets: ["HostwrightNetworking"]),
        .library(name: "HostwrightObservability", targets: ["HostwrightObservability"])
    ],
    targets: [
        .executableTarget(
            name: "HostwrightCLI",
            dependencies: [
                "HostwrightCore",
                "HostwrightHealth",
                "HostwrightManifest",
                "HostwrightReconciler",
                "HostwrightRuntime",
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
            dependencies: ["HostwrightCore"]
        ),
        .target(
            name: "HostwrightRuntime",
            dependencies: ["HostwrightCore"]
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
                "HostwrightManifest",
                "HostwrightNetworking",
                "HostwrightRuntime",
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
            dependencies: ["HostwrightCore"]
        ),
        .target(
            name: "HostwrightNetworking",
            dependencies: ["HostwrightCore"]
        ),
        .target(
            name: "HostwrightObservability",
            dependencies: ["HostwrightCore"]
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
            dependencies: ["HostwrightRuntime"],
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
            dependencies: ["HostwrightReconciler"]
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
                "HostwrightState"
            ]
        ),
        .testTarget(
            name: "HostwrightHealthTests",
            dependencies: ["HostwrightHealth"]
        ),
        .testTarget(
            name: "HostwrightNetworkingTests",
            dependencies: ["HostwrightNetworking"]
        ),
        .testTarget(
            name: "HostwrightObservabilityTests",
            dependencies: ["HostwrightObservability"]
        )
    ]
)

import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime
import HostwrightSecrets
import XCTest

final class RuntimeCreateSubsetPolicyTests: XCTestCase {
    private static let containerizationUnsupportedMessage =
        "Containerization 0.35.0 create does not qualify the requested Phase 04 service options; select the Apple CLI provider or remove unsupported fields before mutation."

    func testAppleContainerCLIAcceptsCompleteExecutablePhase04Subset()
        throws {
        let socketRoot = try HostwrightLocalPathResolver.resolve()
            .layout.publishedSocketDirectory
        let service = makeService(
            platformArchitecture: "amd64",
            cpuCount: 2,
            memoryBytes: 1_073_741_824,
            userID: 501,
            groupID: 20,
            workingDirectory: "/workspace",
            entrypoint: ["/bin/sh", "-c"],
            command: ["exec", "--network"],
            initProcess: true,
            environment: [
                RuntimeEnvironmentValue(
                    name: "API_TOKEN",
                    value: "resolved-value",
                    isSensitive: true
                )
            ],
            labels: ["com.example.role": "api"],
            ports: [
                RuntimePortMapping(
                    hostPort: 18_080,
                    containerPort: 8_080,
                    bindAddress: "127.0.0.1"
                )
            ],
            publishedSockets: [
                RuntimeUnixSocketPublication(
                    hostPath: "\(socketRoot)/api.sock",
                    containerPath: "/run/api.sock",
                    mode: .ownerAndGroup
                )
            ],
            mounts: [
                RuntimeMountReference(
                    source: "/tmp/hostwright-input",
                    target: "/workspace/input",
                    access: .readOnly
                )
            ],
            healthCheck: RuntimeHealthCheckSpec(command: ["/bin/check"]),
            probes: RuntimeProbeSet(
                startup: RuntimeProbeConfiguration(
                    action: .exec(RuntimeProbeExecAction(command: ["/bin/startup"]))
                ),
                readiness: RuntimeProbeConfiguration(
                    action: .http(RuntimeProbeHTTPAction(port: 8_080, path: "/ready"))
                ),
                liveness: RuntimeProbeConfiguration(
                    action: .tcp(RuntimeProbeTCPAction(port: 8_080))
                )
            ),
            hooks: RuntimeLifecycleHooks(
                postStart: ["/bin/post-start"],
                preStop: ["/bin/pre-stop"]
            ),
            rosetta: true,
            virtualization: true,
            readOnlyRootFilesystem: true,
            sharedMemoryBytes: 67_108_864
        )

        XCTAssertNoThrow(
            try RuntimeCreateSubsetPolicy.validate(
                service,
                providerID: .appleContainerCLI
            )
        )
    }

    func testAppleContainerCLIAcceptsTmpfsWithoutUnsupportedMetadata() {
        XCTAssertNoThrow(
            try RuntimeCreateSubsetPolicy.validate(
                makeService(
                    mounts: [
                        RuntimeMountReference(
                            source: "tmpfs",
                            target: "/tmp",
                            kind: .tmpfs,
                            access: .readWrite
                        )
                    ]
                ),
                providerID: .appleContainerCLI
            )
        )
    }

    func testAppleContainerCLIRejectsSocketPathThatExceedsEffectiveGuestRelayLimit()
        throws
    {
        let socketRoot = try HostwrightLocalPathResolver.resolve()
            .layout.publishedSocketDirectory
        let service = makeService(
            publishedSockets: [
                RuntimeUnixSocketPublication(
                    hostPath: "\(socketRoot)/api.sock",
                    containerPath: "/\(String(repeating: "s", count: 70))"
                )
            ]
        )

        XCTAssertThrowsError(
            try RuntimeCreateSubsetPolicy.validate(
                service,
                providerID: .appleContainerCLI
            )
        ) { error in
            guard case RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: let message
            ) = error else {
                return XCTFail("Expected path-limit rejection, got \(error)")
            }
            XCTAssertTrue(message.contains("effective guest relay path limit"))
        }
    }

    func testAppleContainerCLIRejectsDeclaredLANExposureBeforeMutation() {
        let service = makeService(
            ports: [
                RuntimePortMapping(
                    hostPort: 8_443,
                    containerPort: 9_443,
                    protocolName: .tcp,
                    bindAddress: "192.168.1.10",
                    allocation: .fixed,
                    exposurePolicy: HostwrightPortExposurePolicy(
                        scope: .lan,
                        interfaces: ["en0"],
                        networkClasses: [.privateLAN],
                        allowedCIDRs: ["192.168.1.0/24"],
                        authentication: .tls
                    )
                )
            ]
        )

        XCTAssertThrowsError(
            try RuntimeCreateSubsetPolicy.validate(
                service,
                providerID: .appleContainerCLI
            )
        ) { error in
            guard case RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: let message
            ) = error else {
                return XCTFail("Expected secure-listener rejection, got \(error)")
            }
            XCTAssertEqual(
                message,
                "Create-only apply requires a qualified secure listener provider for non-localhost exposure."
            )
        }
    }

    func testAppleContainerCLIRejectsInvalidPlatformAndPortCombinations() {
        let cases: [(String, DesiredRuntimeService)] = [
            (
                "rosetta-on-arm64",
                makeService(rosetta: true, virtualization: true)
            ),
            (
                "amd64-without-rosetta",
                makeService(
                    platformArchitecture: "amd64",
                    virtualization: true
                )
            ),
            (
                "amd64-rosetta-without-virtualization",
                makeService(
                    platformArchitecture: "amd64",
                    rosetta: true
                )
            ),
            (
                "non-loopback-publish",
                makeService(
                    ports: [
                        RuntimePortMapping(
                            hostPort: 18_080,
                            containerPort: 8_080,
                            bindAddress: "192.0.2.10"
                        )
                    ]
                )
            ),
            (
                "out-of-range-container-port",
                makeService(
                    ports: [
                        RuntimePortMapping(
                            hostPort: 18_080,
                            containerPort: 65_536,
                            bindAddress: "127.0.0.1"
                        )
                    ]
                )
            ),
            (
                "tmpfs-mode",
                makeService(
                    mounts: [
                        RuntimeMountReference(
                            source: "tmpfs",
                            target: "/tmp",
                            kind: .tmpfs,
                            access: .readWrite,
                            mode: "1777"
                        )
                    ]
                )
            ),
            (
                "tmpfs-size",
                makeService(
                    mounts: [
                        RuntimeMountReference(
                            source: "tmpfs",
                            target: "/tmp",
                            kind: .tmpfs,
                            access: .readWrite,
                            sizeBytes: 65_536
                        )
                    ]
                )
            )
        ]

        for testCase in cases {
            XCTAssertThrowsError(
                try RuntimeCreateSubsetPolicy.validate(
                    testCase.1,
                    providerID: .appleContainerCLI
                ),
                testCase.0
            )
        }
    }

    func testContainerizationAcceptsOnlyTypedHelperAndLifecycleFields() {
        XCTAssertNoThrow(
            try RuntimeCreateSubsetPolicy.validate(
                makeService(),
                providerID: .appleContainerization
            )
        )
    }

    func testBothProvidersRequireCanonicalGuardedHostAccessBeforeMutation()
        throws
    {
        let projectUUID =
            "11111111-1111-4111-8111-111111111111"
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: projectUUID
        )
        let attachment = try RuntimeDesiredNetworkAttachment(
            network: network
        )
        let endpoint = HostwrightHostAccessEndpoint(
            hostname: "host-api.internal",
            protocolName: .tcp,
            addressClass: .loopback,
            port: 18_080
        )
        for provider in RuntimeProviderID.knownValues {
            XCTAssertNoThrow(
                try RuntimeCreateSubsetPolicy.validate(
                    makeService(
                        hostAccess: [endpoint],
                        networks: [attachment]
                    ),
                    providerID: provider
                )
            )
            XCTAssertThrowsError(
                try RuntimeCreateSubsetPolicy.validate(
                    makeService(hostAccess: [endpoint]),
                    providerID: provider
                )
            )
            var invalid = endpoint
            invalid.hostname = "metadata"
            XCTAssertThrowsError(
                try RuntimeCreateSubsetPolicy.validate(
                    makeService(
                        hostAccess: [invalid],
                        networks: [attachment]
                    ),
                    providerID: provider
                )
            )
            XCTAssertThrowsError(
                try RuntimeCreateSubsetPolicy.validate(
                    makeService(
                        hostAccess: [endpoint, endpoint],
                        networks: [attachment]
                    ),
                    providerID: provider
                )
            )
        }
    }

    func testContainerizationRejectsEveryUnsupportedPhase04FieldWithStableError() throws {
        let secretReference = try HostwrightSecretReference(
            service: "hostwright-test",
            account: "api-token"
        )
        let cases: [(String, DesiredRuntimeService)] = [
            (
                "platform-operating-system",
                makeService(platformOperatingSystem: "darwin")
            ),
            (
                "platform-architecture",
                makeService(platformArchitecture: "amd64")
            ),
            ("cpu-count", makeService(cpuCount: 2)),
            ("memory-bytes", makeService(memoryBytes: 1_073_741_824)),
            ("user-id", makeService(userID: 501)),
            ("group-id", makeService(groupID: 20)),
            ("working-directory", makeService(workingDirectory: "/workspace")),
            ("entrypoint", makeService(entrypoint: ["/bin/sh"])),
            ("init-process", makeService(initProcess: true)),
            ("labels", makeService(labels: ["com.example.role": "api"])),
            (
                "ports",
                makeService(
                    ports: [
                        RuntimePortMapping(
                            hostPort: 18_080,
                            containerPort: 8_080,
                            bindAddress: "127.0.0.1"
                        )
                    ]
                )
            ),
            (
                "published-sockets",
                makeService(
                    publishedSockets: [
                        RuntimeUnixSocketPublication(
                            hostPath: "/tmp/hostwright-api.sock",
                            containerPath: "/run/api.sock"
                        )
                    ]
                )
            ),
            (
                "mounts",
                makeService(
                    mounts: [
                        RuntimeMountReference(
                            source: "/tmp/input",
                            target: "/input",
                            access: .readOnly
                        )
                    ]
                )
            ),
            (
                "health-check",
                makeService(
                    healthCheck: RuntimeHealthCheckSpec(command: ["/bin/check"])
                )
            ),
            (
                "probes",
                makeService(
                    probes: RuntimeProbeSet(
                        startup: RuntimeProbeConfiguration(
                            action: .exec(
                                RuntimeProbeExecAction(command: ["/bin/startup"])
                            )
                        )
                    )
                )
            ),
            (
                "post-start-hook",
                makeService(
                    hooks: RuntimeLifecycleHooks(postStart: ["/bin/post-start"])
                )
            ),
            (
                "pre-stop-hook",
                makeService(
                    hooks: RuntimeLifecycleHooks(preStop: ["/bin/pre-stop"])
                )
            ),
            ("rosetta", makeService(rosetta: true)),
            ("virtualization", makeService(virtualization: true)),
            (
                "read-only-root-filesystem",
                makeService(readOnlyRootFilesystem: true)
            ),
            (
                "shared-memory-bytes",
                makeService(sharedMemoryBytes: 67_108_864)
            ),
            (
                "unresolved-secret-reference",
                makeService(
                    environment: [
                        RuntimeEnvironmentValue(
                            name: "API_TOKEN",
                            value: secretReference.redactedDescription,
                            isSensitive: true,
                            secretReference: secretReference
                        )
                    ]
                )
            )
        ]
        let expected = RuntimeAdapterError.mutationUnavailableByPolicy(
            Self.containerizationUnsupportedMessage
        )

        for testCase in cases {
            XCTAssertThrowsError(
                try RuntimeCreateSubsetPolicy.validate(
                    testCase.1,
                    providerID: .appleContainerization
                ),
                testCase.0
            ) { error in
                XCTAssertEqual(error as? RuntimeAdapterError, expected, testCase.0)
            }
        }
    }

    private func makeService(
        platformOperatingSystem: String = "linux",
        platformArchitecture: String = "arm64",
        cpuCount: Int? = nil,
        memoryBytes: UInt64? = nil,
        userID: UInt32? = nil,
        groupID: UInt32? = nil,
        workingDirectory: String? = nil,
        entrypoint: [String] = [],
        command: [String] = ["/bin/service", "--serve"],
        initProcess: Bool = false,
        environment: [RuntimeEnvironmentValue] = [
            RuntimeEnvironmentValue(name: "MODE", value: "test")
        ],
        labels: [String: String] = [:],
        ports: [RuntimePortMapping] = [],
        publishedSockets: [RuntimeUnixSocketPublication] = [],
        hostAccess: [HostwrightHostAccessEndpoint] = [],
        networks: [RuntimeDesiredNetworkAttachment] = [],
        mounts: [RuntimeMountReference] = [],
        healthCheck: RuntimeHealthCheckSpec? = nil,
        probes: RuntimeProbeSet = RuntimeProbeSet(),
        hooks: RuntimeLifecycleHooks = RuntimeLifecycleHooks(),
        rosetta: Bool = false,
        virtualization: Bool = false,
        readOnlyRootFilesystem: Bool = false,
        sharedMemoryBytes: UInt64? = nil
    ) -> DesiredRuntimeService {
        let identity = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "api",
            instanceName: "replica-1"
        )
        return DesiredRuntimeService(
            identity: identity,
            logicalServiceName: "api",
            replicaIndex: 1,
            image: "example.test/api@sha256:\(String(repeating: "a", count: 64))",
            platformOperatingSystem: platformOperatingSystem,
            platformArchitecture: platformArchitecture,
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            userID: userID,
            groupID: groupID,
            workingDirectory: workingDirectory,
            entrypoint: entrypoint,
            command: command,
            initProcess: initProcess,
            dependencies: [
                RuntimeServiceDependency(
                    serviceName: "worker",
                    condition: .ready
                )
            ],
            environment: environment,
            labels: labels,
            ports: ports,
            publishedSockets: publishedSockets,
            hostAccess: hostAccess,
            networks: networks,
            mounts: mounts,
            healthCheck: healthCheck,
            probes: probes,
            restartPolicy: .onFailure,
            updatePolicy: RuntimeUpdatePolicy(
                strategy: .recreate,
                maxSurge: 0,
                maxUnavailable: 1,
                progressDeadlineSeconds: 120
            ),
            hooks: hooks,
            rosetta: rosetta,
            virtualization: virtualization,
            readOnlyRootFilesystem: readOnlyRootFilesystem,
            sharedMemoryBytes: sharedMemoryBytes
        )
    }
}

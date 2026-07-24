import HostwrightRuntime
import HostwrightSecrets
import XCTest

final class RuntimeCreateSubsetPolicyTests: XCTestCase {
    private static let containerizationUnsupportedMessage =
        "Containerization 0.35.0 create does not qualify the requested Phase 04 service options; select the Apple CLI provider or remove unsupported fields before mutation."

    func testAppleContainerCLIAcceptsCompleteExecutablePhase04Subset() {
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

import XCTest
@testable import HostwrightManifest
@testable import HostwrightNetworking
@testable import HostwrightReconciler
@testable import HostwrightRuntime

final class ManifestRuntimeV3MappingTests: XCTestCase {
    func testMapsProjectNetworksAndServiceAttachmentsWithoutDiscardingAliases() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: demo
            networks:
              frontend: {}
              backend:
                driver: hostOnly
                ipv4: 10.42.0.0/24
                ipv6: fd42::/64
            services:
              api:
                image: local/api:latest
                resources:
                  requests:
                    cpus: 1
                    memory: 512MiB
                  limits:
                    cpus: 1
                    memory: 512MiB
                networks:
                  - frontend
                  - network: backend
                    aliases: [z-api, api]
            """
        )
        let projectUUID = "10000000-0000-4000-8000-000000000001"

        let mapping = ManifestRuntimeMapper.map(
            manifest,
            projectResourceUUID: projectUUID
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(mapping.desiredState.networks.map(\.identity.logicalName), ["backend", "frontend"])
        let backend = try XCTUnwrap(mapping.desiredState.networks.first)
        XCTAssertEqual(backend.identity.projectUUID, projectUUID)
        XCTAssertEqual(backend.mode, .hostOnly)
        XCTAssertEqual(backend.ipv4, .cidr("10.42.0.0/24"))
        XCTAssertEqual(backend.ipv6, .cidr("fd42::/64"))
        XCTAssertTrue(backend.identity.runtimeIdentifier.hasPrefix("hw-"))

        let service = try XCTUnwrap(mapping.desiredState.services.first)
        XCTAssertEqual(service.networks.map(\.networkRuntimeIdentifier), mapping.desiredState.networks.map(\.identity.runtimeIdentifier))
        XCTAssertEqual(service.networks[0].aliases, ["api", "z-api"])
        XCTAssertTrue(service.networks[1].aliases.isEmpty)
        XCTAssertEqual(service.networks[0].networkResourceUUID, backend.identity.resourceUUID)
    }

    func testMapsEveryExecutableManifestV3FieldWithoutDiscardingIt() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api@sha256:\(String(repeating: "a", count: 64))",
            replicas: 2,
            platform: HostwrightPlatform(os: .linux, architecture: .amd64),
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 2, memory: "1GiB"),
                limits: HostwrightResourceSet(cpus: 3, memory: "2GiB")
            ),
            user: 1_001,
            group: 1_002,
            workdir: "/srv/api",
            entrypoint: ["/usr/bin/api", "--foreground"],
            command: ["serve"],
            initProcess: true,
            dependsOn: [
                "db": .ready,
                "migrate": .completed
            ],
            env: ["MODE": "test"],
            labels: ["example.role": "api"],
            ports: ["18080:8080"],
            networkPolicy: HostwrightServiceNetworkPolicy(
                ingress: [
                    HostwrightNetworkPolicyRule(
                        service: "gateway",
                        protocolName: .tcp,
                        port: 8_080
                    )
                ]
            ),
            volumes: ["/tmp/hostwright-api:/data:ro"],
            probes: HostwrightProbes(
                startup: HostwrightProbe(
                    action: .exec(["/usr/bin/check-startup"]),
                    startPeriod: 4,
                    interval: 5,
                    timeout: 2,
                    successThreshold: 1,
                    failureThreshold: 6
                ),
                readiness: HostwrightProbe(
                    action: .http(port: 8080, path: "/ready"),
                    interval: 7,
                    timeout: 3,
                    successThreshold: 2,
                    failureThreshold: 4
                ),
                liveness: HostwrightProbe(
                    action: .tcp(port: 8080),
                    interval: 11,
                    timeout: 4,
                    successThreshold: 1,
                    failureThreshold: 5
                )
            ),
            restart: HostwrightRestart(policy: "unless-stopped"),
            update: HostwrightUpdatePolicy(
                strategy: .recreate,
                maxSurge: 0,
                maxUnavailable: 1,
                progressDeadline: 45
            ),
            hooks: HostwrightHooks(
                postStart: ["/usr/bin/post-start"],
                preStop: ["/usr/bin/pre-stop"]
            ),
            rosetta: true,
            virtualization: true,
            readOnlyRootFilesystem: true,
            shmSize: "64MiB"
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 3, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(mapping.desiredState.services.count, 2)
        let primary = try XCTUnwrap(mapping.desiredState.services.first)
        XCTAssertNil(primary.identity.instanceName)
        XCTAssertEqual(primary.logicalServiceName, "api")
        XCTAssertEqual(primary.replicaIndex, 0)
        XCTAssertEqual(primary.platformOperatingSystem, "linux")
        XCTAssertEqual(primary.platformArchitecture, "amd64")
        XCTAssertEqual(primary.cpuCount, 3)
        XCTAssertNotEqual(primary.cpuCount, service.resources?.requests.cpus)
        XCTAssertEqual(primary.memoryBytes, 2_147_483_648)
        XCTAssertNotEqual(primary.memoryBytes, 1_073_741_824)
        XCTAssertEqual(primary.userID, 1_001)
        XCTAssertEqual(primary.groupID, 1_002)
        XCTAssertEqual(primary.workingDirectory, "/srv/api")
        XCTAssertEqual(primary.entrypoint, ["/usr/bin/api", "--foreground"])
        XCTAssertEqual(primary.command, ["serve"])
        XCTAssertTrue(primary.initProcess)
        XCTAssertEqual(
            primary.dependencies,
            [
                RuntimeServiceDependency(serviceName: "db", condition: .ready),
                RuntimeServiceDependency(serviceName: "migrate", condition: .completed)
            ]
        )
        XCTAssertEqual(primary.environment.map(\.name), ["MODE"])
        XCTAssertEqual(primary.labels, ["example.role": "api"])
        XCTAssertEqual(primary.networkPolicy, service.networkPolicy)
        XCTAssertEqual(primary.ports.first?.bindAddress, "127.0.0.1")
        XCTAssertEqual(primary.mounts.first?.access, .readOnly)
        XCTAssertEqual(primary.probes.startup?.action, .exec(RuntimeProbeExecAction(command: ["/usr/bin/check-startup"])))
        XCTAssertEqual(primary.probes.readiness?.action, .http(RuntimeProbeHTTPAction(port: 8080, path: "/ready")))
        XCTAssertEqual(primary.probes.liveness?.action, .tcp(RuntimeProbeTCPAction(port: 8080)))
        XCTAssertEqual(primary.restartPolicy, .unlessStopped)
        XCTAssertEqual(primary.updatePolicy, RuntimeUpdatePolicy(
            strategy: .recreate,
            maxSurge: 0,
            maxUnavailable: 1,
            progressDeadlineSeconds: 45
        ))
        XCTAssertEqual(primary.hooks.postStart, ["/usr/bin/post-start"])
        XCTAssertEqual(primary.hooks.preStop, ["/usr/bin/pre-stop"])
        XCTAssertTrue(primary.rosetta)
        XCTAssertTrue(primary.virtualization)
        XCTAssertTrue(primary.readOnlyRootFilesystem)
        XCTAssertEqual(primary.sharedMemoryBytes, 67_108_864)
        XCTAssertEqual(mapping.desiredState.services[1].identity.instanceName, "replica-1")
        XCTAssertEqual(mapping.desiredState.services[1].replicaIndex, 1)
    }

    func testReplicaIdentitiesAreStableAcrossManifestServiceOrdering() {
        let digest = String(repeating: "c", count: 64)
        let api = HostwrightService(
            name: "api",
            image: "example.invalid/api@sha256:\(digest)",
            replicas: 3,
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
            )
        )
        let db = HostwrightService(
            name: "db",
            image: "example.invalid/db@sha256:\(digest)",
            replicas: 2,
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
            )
        )

        let first = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 3, project: "demo", services: [api, db])
        )
        let second = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 3, project: "demo", services: [db, api])
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.desiredState.services.map(\.identity.displayName),
            [
                "demo/api",
                "demo/api/replica-1",
                "demo/api/replica-2",
                "demo/db",
                "demo/db/replica-1"
            ]
        )
        XCTAssertEqual(
            Set(first.desiredState.services.map(\.identity.managedResourceIdentifier)).count,
            5
        )
    }

    func testLegacyHealthIsExecutableTypedLiveness() throws {
        let text = """
        version: 3
        project: demo
        services:
          api:
            image: example.invalid/api@sha256:\(String(repeating: "b", count: 64))
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 1
                memory: 512MiB
            health:
              command: ["/usr/bin/health"]
              interval: 9s
        """

        let manifest = try ManifestParser.parse(text)
        let mapped = try XCTUnwrap(ManifestRuntimeMapper.map(manifest).desiredState.services.first)

        XCTAssertEqual(
            mapped.probes.liveness?.action,
            .exec(RuntimeProbeExecAction(command: ["/usr/bin/health"]))
        )
        XCTAssertEqual(mapped.probes.liveness?.intervalSeconds, 9)
        XCTAssertEqual(mapped.healthCheck?.command, ["/usr/bin/health"])
    }

    func testUnsupportedResourceAndSchedulingClaimsBlockBeforeRuntimeMutation() {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            resources: HostwrightResources(
                requests: HostwrightResourceSet(
                    cpus: 1,
                    memory: "512MiB",
                    disk: "1GiB",
                    io: "1MiBps",
                    network: "1Mbps",
                    process: 1
                ),
                limits: HostwrightResourceSet(
                    cpus: 2,
                    memory: "1GiB",
                    disk: "2GiB",
                    io: "2MiBps",
                    network: "2Mbps",
                    process: 2
                )
            ),
            scheduling: HostwrightSchedulingPolicy(
                provider: "apple-container-cli",
                acceleratorClaims: [HostwrightAcceleratorClaim(name: "gpu")]
            )
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 3, project: "demo", services: [service])
        )

        XCTAssertEqual(
            mapping.issues.map { "\($0.stableDetailKey)|\($0.message)" },
            [
                "resources.limits.disk|Disk resource quantities are not enforceable by the selected runtime boundary.",
                "resources.limits.io|I/O resource quantities are not enforceable by the selected runtime boundary.",
                "resources.limits.network|Network resource quantities are not enforceable by the selected runtime boundary.",
                "resources.limits.process|Process resource limits are not enforceable by the selected runtime boundary.",
                "scheduling.acceleratorClaims|Scheduling policy field 'acceleratorClaims' must be admitted by the scheduler before runtime mutation.",
                "scheduling.provider|Scheduling policy field 'provider' must be admitted by the scheduler before runtime mutation.",
            ]
        )
        XCTAssertTrue(mapping.issues.allSatisfy {
            $0.kind == .unsupportedFeature && $0.severity == .blocker
        })
        XCTAssertEqual(mapping.desiredState.services[0].cpuCount, 2)
    }

    func testV3ResourceContractRejectsParityAndOrderingViolationsBeforeMapping() throws {
        let mismatchedDimensions = """
        version: 3
        project: demo
        services:
          api:
            image: local/api:latest
            resources:
              requests:
                cpus: 2
              limits:
                memory: 1GiB
        """
        XCTAssertThrowsError(try ManifestValidator.validated(mismatchedDimensions)) { error in
            guard case .failed(let issues) = error as? ManifestParseError else {
                return XCTFail("Expected structured manifest validation failure, got \(error)")
            }
            XCTAssertEqual(issues.map(\.message), [
                "Service 'api' resources.limits.cpus must be declared when the other side declares it.",
                "Service 'api' resources.requests.memory must be declared when the other side declares it.",
            ])
        }

        let requestExceedsLimit = """
        version: 3
        project: demo
        services:
          api:
            image: local/api:latest
            resources:
              requests:
                cpus: 4
                memory: 2GiB
              limits:
                cpus: 3
                memory: 1GiB
        """
        XCTAssertThrowsError(try ManifestValidator.validated(requestExceedsLimit)) { error in
            guard case .failed(let issues) = error as? ManifestParseError else {
                return XCTFail("Expected structured manifest validation failure, got \(error)")
            }
            XCTAssertEqual(issues.map(\.message), [
                "Service 'api' resources.requests.cpus must not exceed resources.limits.cpus.",
                "Service 'api' resources.requests.memory must not exceed resources.limits.memory.",
            ])
        }

        let validMatchingContract = try ManifestValidator.validated(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/api:latest
                resources:
                  requests:
                    cpus: 1
                    memory: 1GiB
                  limits:
                    cpus: 2
                    memory: 2GiB
            """
        )
        let mapping = ManifestRuntimeMapper.map(validMatchingContract)
        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(mapping.desiredState.services[0].cpuCount, 2)
        XCTAssertEqual(mapping.desiredState.services[0].memoryBytes, 2_147_483_648)
    }

    func testRelativeBindMountResolvesAgainstManifestDirectoryAndDefaultsReadWrite() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
            ),
            volumes: ["./data:/data"]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 3, project: "demo", services: [service]),
            bindMountBaseDirectory: "/tmp/hostwright-project"
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(mapping.desiredState.services[0].mounts[0].source, "/tmp/hostwright-project/data")
        XCTAssertEqual(mapping.desiredState.services[0].mounts[0].access, .readWrite)
    }

    func testTypedBindMountResolvesAgainstManifestDirectory() {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
            ),
            mounts: [
                HostwrightMountSpec(kind: .bind, source: "./data", target: "/data", readOnly: true)
            ]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 3, project: "demo", services: [service]),
            bindMountBaseDirectory: "/tmp/hostwright-project"
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(mapping.desiredState.services[0].mounts, [
            RuntimeMountReference(source: "/tmp/hostwright-project/data", target: "/data", access: .readOnly)
        ])
    }

    func testUnresolvedNamedVolumeIsRejectedBeforeMutation() {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
            ),
            mounts: [
                HostwrightMountSpec(kind: .volume, source: "database", target: "/data")
            ]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 3, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.contains {
            $0.severity == .blocker &&
                $0.message.contains(
                    "not resolved by the selected storage provider"
                )
        })
    }

    func testTmpfsMountMapsThroughToRuntimeWithOptionalSizeAndModeMetadata() {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            resources: HostwrightResources(
                requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
            ),
            mounts: [
                HostwrightMountSpec(kind: .tmpfs, target: "/tmp", readOnly: true, mode: "1777", size: "64MiB")
            ]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 3, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(
            mapping.desiredState.services[0].mounts,
            [
                RuntimeMountReference(
                    source: "",
                    target: "/tmp",
                    kind: .tmpfs,
                    access: .readOnly,
                    mode: "1777",
                    sizeBytes: 67_108_864
                )
            ]
        )
    }
}

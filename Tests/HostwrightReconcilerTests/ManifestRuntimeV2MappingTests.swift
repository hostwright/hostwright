import XCTest
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime

final class ManifestRuntimeV2MappingTests: XCTestCase {
    func testMapsEveryExecutableManifestV2FieldWithoutDiscardingIt() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api@sha256:\(String(repeating: "a", count: 64))",
            replicas: 2,
            platform: HostwrightPlatform(os: .linux, architecture: .amd64),
            resources: HostwrightResources(cpus: 3, memory: "2GiB"),
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
            HostwrightManifest(version: 2, project: "demo", services: [service])
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
        XCTAssertEqual(primary.memoryBytes, 2_147_483_648)
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
            replicas: 3
        )
        let db = HostwrightService(
            name: "db",
            image: "example.invalid/db@sha256:\(digest)",
            replicas: 2
        )

        let first = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [api, db])
        )
        let second = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [db, api])
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
        version: 2
        project: demo
        services:
          api:
            image: example.invalid/api@sha256:\(String(repeating: "b", count: 64))
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

    func testRelativeBindMountResolvesAgainstManifestDirectoryAndDefaultsReadWrite() throws {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            volumes: ["./data:/data"]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [service]),
            bindMountBaseDirectory: "/tmp/hostwright-project"
        )

        XCTAssertTrue(mapping.issues.isEmpty)
        XCTAssertEqual(mapping.desiredState.services[0].mounts[0].source, "/tmp/hostwright-project/data")
        XCTAssertEqual(mapping.desiredState.services[0].mounts[0].access, .readWrite)
    }

    func testNamedVolumeIsRejectedAtThePhaseSixBoundaryBeforeMutation() {
        let service = HostwrightService(
            name: "api",
            image: "example.invalid/api:local",
            volumes: ["database:/data:rw"]
        )

        let mapping = ManifestRuntimeMapper.map(
            HostwrightManifest(version: 2, project: "demo", services: [service])
        )

        XCTAssertTrue(mapping.issues.contains {
            $0.severity == .blocker &&
                $0.message.contains("Phase 06 storage provider")
        })
    }
}

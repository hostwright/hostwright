import XCTest
@testable import HostwrightManifest

final class ManifestV2StrictTests: XCTestCase {
    func testCompleteManifestV3SchemaParsesValidatesAndRoundTripsCanonically() throws {
        let manifest = try ManifestValidator.validated(Self.completeManifest)
        let web = try XCTUnwrap(manifest.services.first { $0.name == "web" })
        let worker = try XCTUnwrap(manifest.services.first { $0.name == "worker" })

        XCTAssertEqual(web.replicas, 1)
        XCTAssertEqual(worker.replicas, 3)
        XCTAssertEqual(web.platform, HostwrightPlatform(os: .linux, architecture: .amd64))
        XCTAssertEqual(
            web.resources,
            HostwrightResources(
                requests: HostwrightResourceSet(cpus: 2, memory: "512MiB"),
                limits: HostwrightResourceSet(cpus: 4, memory: "1GiB")
            )
        )
        XCTAssertEqual(web.user, 1000)
        XCTAssertEqual(web.group, 1000)
        XCTAssertEqual(web.workdir, "/app")
        XCTAssertEqual(web.entrypoint, ["/usr/bin/web"])
        XCTAssertTrue(web.initProcess)
        XCTAssertEqual(web.dependsOn, ["db": .ready])
        XCTAssertEqual(web.labels, ["com.example.role": "frontend"])
        XCTAssertEqual(
            web.publishedPorts,
            [
                HostwrightPublishedPort(
                    host: HostwrightPortSpan(start: 8080),
                    target: HostwrightPortSpan(start: 8080),
                    protocolName: .tcp,
                    bindAddress: HostwrightPublishedPort.localhostBindAddress
                )
            ]
        )
        XCTAssertEqual(web.probes.startup?.action, .exec(["/usr/bin/check", "--startup"]))
        XCTAssertEqual(web.probes.readiness?.action, .tcp(port: 8080))
        XCTAssertEqual(web.probes.liveness?.action, .http(port: 8080, path: "/health"))
        XCTAssertEqual(web.update.strategy, .rolling)
        XCTAssertEqual(web.hooks.postStart, ["/usr/bin/hook", "started"])
        XCTAssertTrue(web.rosetta)
        XCTAssertTrue(web.readOnlyRootFilesystem)
        XCTAssertEqual(web.shmSize, "64MiB")

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertEqual(canonical, try ManifestCanonicalEncoder.encode(manifest))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #""A": "first""#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #""Z": "last""#)?.lowerBound)
        )
    }

    func testCheckedInManifestCorpusRoundTripsThroughCanonicalEncoding() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            root.appendingPathComponent("contracts/v0.0.2/manifest.yaml")
        ] + (try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("examples"),
            includingPropertiesForKeys: nil
        )).map { $0.appendingPathComponent("hostwright.yaml") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        for path in paths {
            let parsed = try ManifestValidator.validated(String(contentsOf: path, encoding: .utf8))
            let canonical = try ManifestCanonicalEncoder.encode(parsed)
            XCTAssertEqual(try ManifestValidator.validated(canonical), parsed, path.path)
            XCTAssertEqual(
                try ManifestCanonicalEncoder.encode(ManifestValidator.validated(canonical)),
                canonical,
                path.path
            )
        }
    }

    func testRejectsDuplicateKeysAtNestedLevelsWithSourceLocation() {
        assertFailure(
            """
            version: 3
            project: demo
            volumes:
              cache-data:
                capacity: 256MiB
            services:
              api:
                image: local/demo:latest
                env:
                  MODE: first
                  MODE: second
            """,
            contains: "duplicate keys: MODE",
            path: "$"
        )
    }

    func testRejectsAnchorsAliasesMergeKeysAndCustomTags() {
        for source in [
            """
            version: 3
            project: demo
            services: &services
              api:
                image: local/demo:latest
            """,
            """
            version: 3
            project: demo
            services:
              api: &api
                image: local/demo:latest
              worker: *api
            """,
            """
            version: 3
            project: demo
            services: !custom
              api:
                image: local/demo:latest
            """,
            """
            version: 3
            project: demo
            services:
              api:
                <<: {image: local/demo:latest}
            """
        ] {
            assertFailure(source, code: "HW-MANIFEST-003")
        }
    }

    func testRejectsMultipleDocumentsAmbiguousScalarsAndUnknownFields() {
        assertFailure(
            "version: 3\nproject: one\nservices: {}\n---\nversion: 3\nproject: two\nservices: {}\n",
            contains: "another document"
        )
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                env:
                  ENABLED: on
            """,
            contains: "unambiguous string",
            path: "$.services.api.env.ENABLED"
        )
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                mystery: value
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported service field 'mystery'",
            path: "$.services.api.mystery"
        )
    }

    func testRejectsByteDepthAndExpandedNodeLimits() {
        assertFailure(
            String(repeating: "a", count: ManifestParser.maximumUTF8Bytes + 1),
            code: "HW-MANIFEST-003",
            contains: "1 MiB"
        )

        let nested = String(repeating: "[", count: 70) + #""x""# + String(repeating: "]", count: 70)
        assertFailure(
            "version: 3\nproject: demo\nservices:\n  api:\n    image: local/demo:latest\n    command: \(nested)\n",
            code: "HW-MANIFEST-003",
            contains: "maximum depth"
        )

        let values = Array(repeating: "x", count: ManifestParser.maximumExpandedNodes).joined(separator: ",")
        assertFailure(
            "version: 3\nproject: demo\nservices:\n  api:\n    image: local/demo:latest\n    command: [\(values)]\n",
            code: "HW-MANIFEST-003",
            contains: "expanded node count"
        )
    }

    func testCancellationAndPartialDocumentsFailWithoutProducingAManifest() {
        XCTAssertThrowsError(
            try ManifestParser.parse(Self.completeManifest, cancellationCheck: { true })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        assertFailure(
            "version: 3\nproject: demo\nservices:\n  api:\n    image: [",
            contains: "Invalid YAML"
        )
    }

    func testLegacyHealthMigratesToTypedLivenessDeterministically() throws {
        let source = """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
            health:
              command: ["/usr/bin/check", "--ready"]
              interval: 7s
        """
        let preview = try ManifestMigrator.previewV3(source)

        XCTAssertEqual(preview.changes, [.migrateLegacyHealth])
        XCTAssertFalse(preview.migratedManifest.contains("\n    health:"))
        XCTAssertTrue(preview.migratedManifest.contains("\n    probes:"))
        let migrated = try ManifestValidator.validated(preview.migratedManifest)
        XCTAssertEqual(migrated.services[0].probes.liveness?.action, .exec(["/usr/bin/check", "--ready"]))
        XCTAssertEqual(migrated.services[0].probes.liveness?.interval, 7)
    }

    func testTypedMountObjectsParseValidateAndRoundTripCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: demo
            volumes:
              cache-data:
                capacity: 256MiB
            services:
              api:
                image: local/demo:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                volumes:
                  - type: bind
                    source: ./data
                    target: /data
                    readOnly: true
                  - type: volume
                    source: cache-data
                    target: /cache
                  - type: tmpfs
                    target: /tmp
                    mode: "1777"
                    size: 64MiB
            """
        )

        let mounts = manifest.services[0].mounts
        XCTAssertEqual(mounts.count, 3)
        XCTAssertEqual(mounts[0], HostwrightMountSpec(kind: .bind, source: "./data", target: "/data", readOnly: true))
        XCTAssertEqual(mounts[1], HostwrightMountSpec(kind: .volume, source: "cache-data", target: "/cache"))
        XCTAssertEqual(mounts[2], HostwrightMountSpec(kind: .tmpfs, target: "/tmp", mode: "1777", size: "64MiB"))
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testTypedMountObjectsRejectUnknownFieldsAndInvalidTmpfsMode() {
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                volumes:
                  - type: bind
                    source: ./data
                    target: /data
                    mystery: true
            """,
            contains: "Unsupported service field 'mystery'",
            path: "$.services.api.volumes[0].mystery"
        )

        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                volumes:
                  - type: tmpfs
                    target: /tmp
                    mode: "888"
            """,
            contains: "three- or four-digit octal string",
            requireSource: false
        )
    }

    func testTopLevelVolumesParseValidateAndRoundTripCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: demo
            volumes:
              archive:
                provider: acme.storage-v1
                capacity: 2GiB
                accessMode: read-only-many
                reclaimPolicy: backup-before-delete
                labels:
                  com.example.tier: cold
                  com.example.zone: z1
              cache:
                capacity: 512MiB
            services:
              api:
                image: local/demo:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                volumes:
                  - type: volume
                    source: cache
                    target: /cache
            """
        )

        XCTAssertEqual(
            manifest.volumes["archive"],
            HostwrightVolumeDeclaration(
                provider: "acme.storage-v1",
                capacity: "2GiB",
                accessMode: .readOnlyMany,
                reclaimPolicy: .backupBeforeDelete,
                labels: [
                    "com.example.tier": "cold",
                    "com.example.zone": "z1"
                ]
            )
        )
        XCTAssertEqual(
            manifest.volumes["cache"],
            HostwrightVolumeDeclaration(capacity: "512MiB")
        )
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #""archive":"#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #""cache":"#)?.lowerBound)
        )
    }

    func testTopLevelVolumesRejectUnsupportedFieldsInvalidValuesAndReservedLabels() {
        assertFailure(
            """
            version: 3
            project: demo
            volumes:
              cache:
                capacity: 512MiB
                mystery: true
            services:
              api:
                image: local/demo:latest
            """,
            contains: "Unsupported top-level volume field 'mystery'",
            path: "$.volumes.cache.mystery"
        )
        assertFailure(
            """
            version: 3
            project: demo
            volumes:
              cache:
                provider: Bad/Provider
                capacity: 512MiB
            services:
              api:
                image: local/demo:latest
            """,
            contains: "bounded stable provider ID",
            requireSource: false
        )
        assertFailure(
            """
            version: 3
            project: demo
            volumes:
              cache:
                capacity: 0GiB
            services:
              api:
                image: local/demo:latest
            """,
            contains: "capacity must be a normalized positive size",
            requireSource: false
        )
        assertFailure(
            """
            version: 3
            project: demo
            volumes:
              cache:
                capacity: 512MiB
                labels:
                  dev.hostwright.owner: reserved
            services:
              api:
                image: local/demo:latest
            """,
            contains: "reserved Hostwright ownership prefix",
            requireSource: false
        )
    }

    func testVolumeMountMustReferenceDeclaredTopLevelVolumeButUnusedDeclarationsAreAllowed() throws {
        let valid = try ManifestValidator.validated(
            """
            version: 3
            project: demo
            volumes:
              cache:
                capacity: 512MiB
              unused:
                capacity: 1GiB
            services:
              api:
                image: local/demo:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                volumes:
                  - type: volume
                    source: cache
                    target: /cache
            """
        )
        XCTAssertEqual(Set(valid.volumes.keys), ["cache", "unused"])

        assertFailure(
            """
            version: 3
            project: demo
            volumes:
              cache:
                capacity: 512MiB
            services:
              api:
                image: local/demo:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                volumes:
                  - type: volume
                    source: missing
                    target: /cache
            """,
            contains: "must reference a declared top-level volume",
            requireSource: false
        )
    }

    func testSizeValidationAcceptsUInt64ByteBoundaries() {
        XCTAssertNoThrow(
            try ManifestValidator.validated(
                """
                version: 3
                project: demo
                services:
                  api:
                    image: local/demo:latest
                    resources:
                      requests:
                        cpus: 1
                        memory: "18446744073709551615B"
                      limits:
                        cpus: 1
                        memory: "18446744073709551615B"
                    shmSize: "16777215TiB"
                """
            )
        )
    }

    func testSizeValidationRejectsUInt64ParsingAndMultiplicationOverflow() {
        for source in [
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    memory: "18446744073709551616B"
                  limits:
                    memory: "18446744073709551616B"
            """,
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                shmSize: "16777216TiB"
            """
        ] {
            assertFailure(
                source,
                contains: "exceeds UInt64 byte capacity",
                requireSource: false
            )
        }
    }

    func testV3ResourcesRequireNonEmptyMatchingDimensionsAndCPUMemory() throws {
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources: {}
            """,
            contains: "resources.requests must declare at least one quantity",
            requireSource: false
        )
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    cpus: 2
                  limits:
                    memory: 1GiB
            """,
            contains: "resources.limits.cpus must be declared when the other side declares it",
            requireSource: false
        )
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    cpus: 2
                  limits:
                    cpus: 3
                    memory: 1GiB
            """,
            contains: "resources.requests.memory must be declared when the other side declares it",
            requireSource: false
        )

        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    memory: 512MiB
                  limits:
                    memory: 1GiB
            """,
            contains: "resources.requests.cpus must be declared",
            requireSource: false
        )
        XCTAssertNoThrow(
            try ManifestValidator.validated(
                """
                version: 3
                project: demo
                services:
                  api:
                    image: local/demo:latest
                    resources:
                      requests:
                        cpus: 1
                        memory: 512MiB
                      limits:
                        cpus: 1
                        memory: 1GiB
                """
            )
        )
    }

    func testV3FlatResourcesAreRejectedBeforeValidation() {
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  cpus: 2
                  memory: 1GiB
            """,
            contains: "Flat resources.cpus/resources.memory are legacy input",
            requireSource: false
        )
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  cpus: 2
                  requests:
                    cpus: 2
                  limits:
                    cpus: 2
            """,
            contains: "resources cannot mix legacy flat cpus/memory with nested requests/limits",
            requireSource: false
        )
    }

    func testV3ResourceComparisonAndSchedulingDiagnosticsUseActionableFields() {
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    cpus: 4
                    memory: 512MiB
                  limits:
                    cpus: 2
                    memory: 512MiB
            """,
            contains: "resources.requests.cpus must not exceed resources.limits.cpus",
            requireSource: false
        )
        XCTAssertNoThrow(
            try ManifestValidator.validated(
                """
                version: 3
                project: demo
                services:
                  api:
                    image: local/demo:latest
                    resources:
                      requests: {cpus: 1, memory: 512MiB}
                      limits: {cpus: 1, memory: 512MiB}
                    scheduling:
                      requiredAffinity:
                        - key: topology.zone
                          operator: exists
                      requiredAntiAffinity:
                        - key: topology.zone
                          operator: exists
                """
            )
        )
    }

    func testSchedulingIsTheOnlyProviderAndAcceleratorClaimSource() {
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    cpus: 1
                    provider: apple-container-cli
                  limits:
                    cpus: 1
                    provider: apple-container-cli
            """,
            contains: "Unsupported service field 'provider'",
            path: "$.services.api.resources.requests.provider"
        )
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  requests:
                    cpus: 1
                    acceleratorClaims:
                      - name: gpu
                  limits:
                    cpus: 1
                    acceleratorClaims:
                      - name: gpu
            """,
            contains: "Unsupported service field 'acceleratorClaims'",
            path: "$.services.api.resources.requests.acceleratorClaims"
        )
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                scheduling:
                  acceleratorClaims:
                    - name: gpu
                    - name: gpu
            """,
            contains: "scheduling.acceleratorClaims must not contain duplicate claim names",
            requireSource: false
        )
    }

    func testValidationRejectsDuplicateFixedLocalhostPortAcrossServices() {
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                ports:
                  - "8080:8080"
              worker:
                image: local/worker:latest
                ports:
                  - "8080:9090"
            """,
            contains: "Fixed localhost port 8080 is published by multiple services: api, worker",
            requireSource: false
        )
    }

    func testValidationRejectsFixedLocalhostPortWithMultipleReplicas() {
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/api:latest
                replicas: 2
                ports:
                  - "8080:8080"
            """,
            contains: "replicas cannot share fixed localhost ports: 8080",
            requireSource: false
        )
    }

    func testValidationRejectsInvalidBoundsAndCrossFieldCombinations() {
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/demo:latest
                replicas: 257
                platform:
                  architecture: arm64
                resources:
                  requests:
                    cpus: 0
                    memory: 512MB
                  limits:
                    cpus: 1
                    memory: 512MiB
                rosetta: true
                labels:
                  dev.hostwright.resource-uuid: forbidden
                update:
                  maxSurge: 0
                  maxUnavailable: 0
            """,
            contains: "replicas must be between 1 and 256",
            requireSource: false
        )
    }

    func testValidationRejectsInvalidStructuredPortDeclarations() {
        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                ports:
                  - bind: localhost
                    host: "18080-18082"
                    target: "8080-8081"
                    protocol: sctp
            """,
            contains: "protocol must be one of: tcp, udp, unix",
            requireSource: false
        )

        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                ports:
                  - bind: 127.0.0.1
                    host: 80
                    target: 8080
            """,
            contains: "fixed published ports must be 1024 or higher",
            requireSource: false
        )

        assertFailure(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                ports:
                  - bind: 127.0.0.1
                    host: "18080-18082"
                    target: "8080-8081"
            """,
            contains: "structured port ranges must have equal host and target lengths",
            requireSource: false
        )
    }

    func testProbePortsUseStructuredTargetPorts() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                ports:
                  - bind: 127.0.0.1
                    host: 18080
                    target: 8080
                    protocol: tcp
                probes:
                  readiness:
                    tcp:
                      port: 8080
            """
        )

        XCTAssertEqual(manifest.services[0].probes.readiness?.action, .tcp(port: 8080))
    }

    func testDynamicPublishedPortRangeIsAcceptedAndCanonical() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: demo
            services:
              api:
                image: local/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                ports:
                  - target: "8080-8082"
                    protocol: udp
            """
        )

        let port = try XCTUnwrap(manifest.services.first?.publishedPorts.first)
        XCTAssertNil(port.host)
        XCTAssertEqual(port.target, HostwrightPortSpan(start: 8080, end: 8082))
        XCTAssertEqual(port.protocolName, .udp)
        XCTAssertTrue(
            try ManifestCanonicalEncoder.encode(manifest).contains(
                #"target: "8080-8082""#
            )
        )
    }

    func testBoundedDeterministicMutationSmokeHasStableOutcomes() throws {
        let original = Array(Self.completeManifest.utf8)
        let replacements: [UInt8] = [0x09, 0x0A, 0x20, 0x23, 0x26, 0x2A, 0x3A, 0x5B, 0x5D, 0x7B, 0x7D, 0x7F]
        var seed: UInt64 = 0x484F_5354_5752_4947

        for iteration in 0..<96 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            var mutated = original
            let index = Int(seed % UInt64(mutated.count))
            mutated[index] = replacements[(iteration + Int(seed >> 32)) % replacements.count]
            let source = String(decoding: mutated, as: UTF8.self)

            do {
                let manifest = try ManifestValidator.validated(source)
                let canonical = try ManifestCanonicalEncoder.encode(manifest)
                XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
                XCTAssertEqual(try ManifestCanonicalEncoder.encode(manifest), canonical)
            } catch let first as ManifestParseError {
                XCTAssertFalse(first.issues.isEmpty)
                XCTAssertThrowsError(try ManifestValidator.validated(source)) { second in
                    XCTAssertEqual(second as? ManifestParseError, first)
                }
            }
        }
    }

    private func assertFailure(
        _ source: String,
        code: String? = nil,
        contains text: String? = nil,
        path: String? = nil,
        requireSource: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ManifestValidator.validated(source), file: file, line: line) { error in
            guard let failure = error as? ManifestParseError else {
                return XCTFail("Expected ManifestParseError, got \(error).", file: file, line: line)
            }
            XCTAssertTrue(
                failure.issues.contains { issue in
                    (code == nil || issue.code.rawValue == code)
                        && (text == nil || issue.message.contains(text!))
                        && (path == nil || issue.path == path)
                },
                "Expected code=\(code ?? "*") text=\(text ?? "*") path=\(path ?? "*"), got \(failure.issues)",
                file: file,
                line: line
            )
            if requireSource {
                XCTAssertTrue(
                    failure.issues.allSatisfy { $0.line != nil || $0.path == "$" },
                    "Expected stable source position for non-root issue: \(failure.issues)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private static let completeManifest = """
    version: 3
    project: full-v2
    imagePolicy: allow-tags
    services:
      web:
        image: local/web:latest
        platform:
          os: linux
          architecture: amd64
        resources:
          requests:
            cpus: 2
            memory: 512MiB
          limits:
            cpus: 4
            memory: 1GiB
        user: 1000
        group: 1000
        workdir: /app
        entrypoint: ["/usr/bin/web"]
        command: ["serve"]
        init: true
        dependsOn:
          db: ready
        env:
          Z: last
          A: first
        secretEnv:
          API_TOKEN: keychain://hostwright.web/api-token
        labels:
          com.example.role: frontend
        ports:
          - "8080:8080"
        volumes:
          - "./data:/data:ro"
        probes:
          startup:
            exec: ["/usr/bin/check", "--startup"]
            interval: 2s
            timeout: 1s
            failureThreshold: 5
          readiness:
            tcp:
              port: 8080
          liveness:
            http:
              port: 8080
              path: /health
            startPeriod: 5s
        restart:
          policy: on-failure
        update:
          strategy: rolling
          maxSurge: 1
          maxUnavailable: 1
          progressDeadline: 60s
        hooks:
          postStart:
            exec: ["/usr/bin/hook", "started"]
          preStop:
            exec: ["/usr/bin/hook", "stopping"]
        rosetta: true
        virtualization: true
        readOnlyRootFilesystem: true
        shmSize: 64MiB
      db:
        image: local/db:latest
        resources:
          requests: {cpus: 1, memory: 512MiB}
          limits: {cpus: 1, memory: 512MiB}
        restart:
          policy: unless-stopped
      worker:
        image: local/worker:latest
        resources:
          requests: {cpus: 1, memory: 512MiB}
          limits: {cpus: 1, memory: 512MiB}
        replicas: 3
    """
}

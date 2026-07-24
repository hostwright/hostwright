import XCTest
@testable import HostwrightManifest

final class ManifestV2StrictTests: XCTestCase {
    func testCompleteManifestV2SchemaParsesValidatesAndRoundTripsCanonically() throws {
        let manifest = try ManifestValidator.validated(Self.completeManifest)
        let web = try XCTUnwrap(manifest.services.first { $0.name == "web" })
        let worker = try XCTUnwrap(manifest.services.first { $0.name == "worker" })

        XCTAssertEqual(web.replicas, 1)
        XCTAssertEqual(worker.replicas, 3)
        XCTAssertEqual(web.platform, HostwrightPlatform(os: .linux, architecture: .amd64))
        XCTAssertEqual(web.resources, HostwrightResources(cpus: 2, memory: "512MiB"))
        XCTAssertEqual(web.user, 1000)
        XCTAssertEqual(web.group, 1000)
        XCTAssertEqual(web.workdir, "/app")
        XCTAssertEqual(web.entrypoint, ["/usr/bin/web"])
        XCTAssertTrue(web.initProcess)
        XCTAssertEqual(web.dependsOn, ["db": .ready])
        XCTAssertEqual(web.labels, ["com.example.role": "frontend"])
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
            version: 2
            project: demo
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
            version: 2
            project: demo
            services: &services
              api:
                image: local/demo:latest
            """,
            """
            version: 2
            project: demo
            services:
              api: &api
                image: local/demo:latest
              worker: *api
            """,
            """
            version: 2
            project: demo
            services: !custom
              api:
                image: local/demo:latest
            """,
            """
            version: 2
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
            "version: 2\nproject: one\nservices: {}\n---\nversion: 2\nproject: two\nservices: {}\n",
            contains: "another document"
        )
        assertFailure(
            """
            version: 2
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
            version: 2
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
            "version: 2\nproject: demo\nservices:\n  api:\n    image: local/demo:latest\n    command: \(nested)\n",
            code: "HW-MANIFEST-003",
            contains: "maximum depth"
        )

        let values = Array(repeating: "x", count: ManifestParser.maximumExpandedNodes).joined(separator: ",")
        assertFailure(
            "version: 2\nproject: demo\nservices:\n  api:\n    image: local/demo:latest\n    command: [\(values)]\n",
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
            "version: 2\nproject: demo\nservices:\n  api:\n    image: [",
            contains: "Invalid YAML"
        )
    }

    func testLegacyHealthMigratesToTypedLivenessDeterministically() throws {
        let source = """
        version: 2
        project: demo
        services:
          api:
            image: local/demo:latest
            health:
              command: ["/usr/bin/check", "--ready"]
              interval: 7s
        """
        let preview = try ManifestMigrator.previewV2(source)

        XCTAssertEqual(preview.changes, [.migrateLegacyHealth])
        XCTAssertFalse(preview.migratedManifest.contains("\n    health:"))
        XCTAssertTrue(preview.migratedManifest.contains("\n    probes:"))
        let migrated = try ManifestValidator.validated(preview.migratedManifest)
        XCTAssertEqual(migrated.services[0].probes.liveness?.action, .exec(["/usr/bin/check", "--ready"]))
        XCTAssertEqual(migrated.services[0].probes.liveness?.interval, 7)
    }

    func testSizeValidationAcceptsUInt64ByteBoundaries() {
        XCTAssertNoThrow(
            try ManifestValidator.validated(
                """
                version: 2
                project: demo
                services:
                  api:
                    image: local/demo:latest
                    resources:
                      memory: "18446744073709551615B"
                    shmSize: "16777215TiB"
                """
            )
        )
    }

    func testSizeValidationRejectsUInt64ParsingAndMultiplicationOverflow() {
        for source in [
            """
            version: 2
            project: demo
            services:
              api:
                image: local/demo:latest
                resources:
                  memory: "18446744073709551616B"
            """,
            """
            version: 2
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

    func testValidationRejectsDuplicateFixedLocalhostPortAcrossServices() {
        assertFailure(
            """
            version: 2
            project: demo
            services:
              api:
                image: local/api:latest
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
            version: 2
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
            version: 2
            project: demo
            services:
              api:
                image: local/demo:latest
                replicas: 257
                platform:
                  architecture: arm64
                resources:
                  cpus: 0
                  memory: 512MB
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
    version: 2
    project: full-v2
    imagePolicy: allow-tags
    services:
      web:
        image: local/web:latest
        platform:
          os: linux
          architecture: amd64
        resources:
          cpus: 2
          memory: 512MiB
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
        restart:
          policy: unless-stopped
      worker:
        image: local/worker:latest
        replicas: 3
    """
}

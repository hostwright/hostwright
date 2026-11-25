import Foundation
import XCTest
@testable import HostwrightManifest

final class Phase04ExecutableExamplesTests: XCTestCase {
    private let image =
        "docker.io/library/python@sha256:" +
        "26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92"

    func testRunnableManifestsUseOnlyPinnedPreloadedImageAndRoundTrip() throws {
        for relativePath in [
            "examples/single-service/hostwright.yaml",
            "examples/app-suite/hostwright.yaml",
            "examples/api-redis/hostwright.yaml",
            "examples/unhealthy-rollback/hostwright.yaml",
            "examples/unhealthy-rollback/unhealthy.yaml"
        ] {
            let source = try read(relativePath)
            let manifest = try ManifestValidator.validated(source)
            let canonical = try ManifestCanonicalEncoder.encode(manifest)

            XCTAssertEqual(manifest.imagePolicy, .requireDigest, relativePath)
            XCTAssertTrue(
                manifest.services.allSatisfy { $0.image == image },
                relativePath
            )
            XCTAssertEqual(
                try ManifestValidator.validated(canonical),
                manifest,
                relativePath
            )
            XCTAssertFalse(source.lowercased().contains("pull"), relativePath)
        }
    }

    func testThreeServiceExampleLocksDependenciesReplicasProbesAndUpdates() throws {
        let manifest = try manifest("examples/app-suite/hostwright.yaml")
        XCTAssertEqual(Set(manifest.services.map(\.name)), ["prepare", "worker", "web"])

        let prepare = try service("prepare", in: manifest)
        let worker = try service("worker", in: manifest)
        let web = try service("web", in: manifest)

        XCTAssertEqual(prepare.replicas, 1)
        XCTAssertEqual(worker.replicas, 2)
        XCTAssertTrue(worker.ports.isEmpty)
        XCTAssertEqual(worker.dependsOn, ["prepare": .completed])
        XCTAssertNotNil(worker.probes.startup)
        XCTAssertNotNil(worker.probes.readiness)
        XCTAssertNotNil(worker.probes.liveness)
        XCTAssertEqual(worker.update.strategy, .rolling)
        XCTAssertEqual(worker.update.maxSurge, 1)
        XCTAssertEqual(worker.update.maxUnavailable, 1)

        XCTAssertEqual(web.dependsOn, ["worker": .ready])
        XCTAssertEqual(web.ports, ["18081:8080"])
        XCTAssertEqual(web.probes.readiness?.action, .tcp(port: 8080))
        XCTAssertEqual(web.probes.liveness?.action, .http(port: 8080, path: "/"))
        XCTAssertEqual(web.update.strategy, .recreate)
    }

    func testUnhealthyRevisionChangesOnlyExecutableHealthOutcome() throws {
        let healthy = try manifest("examples/unhealthy-rollback/hostwright.yaml")
        let unhealthy = try manifest("examples/unhealthy-rollback/unhealthy.yaml")
        let healthyWeb = try service("web", in: healthy)
        let unhealthyWeb = try service("web", in: unhealthy)

        XCTAssertEqual(healthy.project, unhealthy.project)
        XCTAssertEqual(healthyWeb.image, unhealthyWeb.image)
        XCTAssertEqual(healthyWeb.command, unhealthyWeb.command)
        XCTAssertEqual(healthyWeb.ports, unhealthyWeb.ports)
        XCTAssertEqual(healthyWeb.probes.readiness?.action, .tcp(port: 8080))
        XCTAssertEqual(
            unhealthyWeb.probes.readiness?.action,
            .exec(["python3", "-c", "raise SystemExit(1)"])
        )
        XCTAssertEqual(unhealthyWeb.update.strategy, .recreate)
        XCTAssertLessThan(
            unhealthyWeb.update.progressDeadline,
            healthyWeb.update.progressDeadline
        )
    }

    func testExpectedFailureExamplesUseOnlyRepresentablePreMutationBoundaries() throws {
        let namedSource = try read(
            "examples/expected-failures/named-volume.yaml"
        )
        let named = try ManifestParser.parse(namedSource)
        let secret = try manifest("examples/expected-failures/unavailable-secret.yaml")
        let networkSource = try read(
            "examples/expected-failures/unsupported-network.yaml"
        )
        let namedApp = try service("app", in: named)
        let secretApp = try service("app", in: secret)

        XCTAssertEqual(namedApp.image, image)
        XCTAssertEqual(namedApp.volumes, ["phase04-data:/data"])
        XCTAssertThrowsError(
            try ManifestValidator.validated(namedSource)
        ) { error in
            guard let parseError = error as? ManifestParseError,
                  let issue = parseError.issues.first else {
                return XCTFail(
                    "Expected one structured manifest issue: \(error)"
                )
            }
            XCTAssertEqual(
                issue.code.rawValue,
                "HW-MANIFEST-002"
            )
            XCTAssertTrue(
                issue.message.contains(
                    "must reference a declared top-level volume"
                ),
                issue.message
            )
        }
        XCTAssertEqual(
            secretApp.secretEnv["API_TOKEN"]?.rawValue,
            "keychain://hostwright.phase04/api-token"
        )
        XCTAssertTrue(secretApp.env.isEmpty)
        XCTAssertThrowsError(try ManifestValidator.validated(networkSource)) { error in
            guard let parseError = error as? ManifestParseError,
                  let issue = parseError.issues.first else {
                return XCTFail("Expected one structured manifest issue: \(error)")
            }
            XCTAssertEqual(issue.code.rawValue, "HW-MANIFEST-002")
            XCTAssertTrue(
                issue.message.contains("must reference a declared top-level network"),
                issue.message
            )
            XCTAssertEqual(issue.path, "$.services.app.networks")
        }

        let directory = packageRoot()
            .appendingPathComponent("examples/expected-failures")
        let yamlNames = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
            .filter { $0.pathExtension == "yaml" }
            .map(\.lastPathComponent)
            .sorted()
        XCTAssertEqual(
            yamlNames,
            [
                "named-volume.yaml",
                "unavailable-secret.yaml",
                "unsupported-network.yaml"
            ]
        )
        let explanation = try read("examples/expected-failures/README.md")
        XCTAssertTrue(explanation.contains("Phase 07"))
        XCTAssertFalse(explanation.contains("hostwright pull"))
    }

    private func manifest(_ relativePath: String) throws -> HostwrightManifest {
        try ManifestValidator.validated(read(relativePath))
    }

    private func service(
        _ name: String,
        in manifest: HostwrightManifest
    ) throws -> HostwrightService {
        try XCTUnwrap(manifest.services.first { $0.name == name })
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

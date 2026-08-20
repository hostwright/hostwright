import Foundation
import XCTest
@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore

final class CLIControlRouteTests: XCTestCase {
    func testLocalBootstrapPersistentAndStreamRoutesAreDisjoint() throws {
        XCTAssertEqual(
            try CLIControlRoute.classify(arguments: ["--version"]).transport,
            .localPresentation
        )
        XCTAssertEqual(
            try CLIControlRoute.classify(arguments: [
                "daemon", "repair", "--output", "json",
            ]).transport,
            .bootstrapAPI
        )
        XCTAssertEqual(
            try CLIControlRoute.classify(arguments: ["capabilities", "--json"]).transport,
            .persistentControlAPI
        )
        XCTAssertEqual(
            try CLIControlRoute.classify(arguments: [
                "exec", "api", "--no-stdin", "--", "/bin/true",
            ]).execution,
            .stream(.exec)
        )
    }

    func testFrozenParityInventoryRoutesEveryTopLevelCommand() throws {
        for entry in frozenInventory {
            let route = try CLIControlRoute.classify(arguments: entry.arguments)
            XCTAssertEqual(
                route.transport,
                entry.transport,
                "\(entry.command): \(entry.arguments.joined(separator: " "))"
            )
        }
    }

    func testReadAndMutationClassificationUsesParsedCommandSemantics() throws {
        let cases: [([String], Bool)] = [
            (["capabilities"], false),
            (["state", "integrity"], false),
            (["state", "backup"], true),
            (["daemon", "status"], false),
            (["daemon", "repair"], true),
            (["events"], false),
            (["image", "inspect", "alpine:3.20"], false),
            (["image", "pull", "alpine:3.20"], true),
            (["volume", "list"], false),
            (["volume", "prune", "--dry-run"], true),
            (["exec", "api", "--no-stdin", "--", "/bin/true"], true),
            (["inspect", "api"], false),
            (["export-stack", "hostwright.yaml"], false),
            (["plan-stack-update", "current.yaml", "desired.yaml"], false),
        ]

        for (arguments, expectedMutation) in cases {
            XCTAssertEqual(
                try CLIControlRoute.classify(arguments: arguments).mutating,
                expectedMutation,
                arguments.joined(separator: " ")
            )
        }
    }

    func testComposeExportAndUpdatePlanRoutesArePersistentUnaryAndReadOnly() throws {
        let cases: [[String]] = [
            ["export-stack", "hostwright.yaml", "--output", "json"],
            ["plan-stack-update", "current.yaml", "desired.yaml", "--output", "json"],
        ]

        for arguments in cases {
            let route = try CLIControlRoute.classify(arguments: arguments)
            XCTAssertEqual(route.transport, .persistentControlAPI)
            XCTAssertEqual(route.execution, .unary)
            XCTAssertFalse(route.mutating)
            XCTAssertEqual(route.output, .json)
            let request = request(route: route)
            XCTAssertNil(request.idempotencyKey)
            XCTAssertEqual(try CLIControlRoute.validate(request: request), route)
        }
    }

    func testEveryNestedParsedActionHasExactTextAndJSONRouteParity() throws {
        for entry in nestedActionInventory {
            let jsonRoute = try CLIControlRoute.classify(arguments: entry.jsonArguments)
            XCTAssertEqual(jsonRoute.transport, .persistentControlAPI, entry.name)
            XCTAssertEqual(jsonRoute.execution, .unary, entry.name)
            XCTAssertEqual(jsonRoute.operation, entry.operation, entry.name)
            XCTAssertEqual(jsonRoute.subcommand, entry.subcommand, entry.name)
            XCTAssertEqual(jsonRoute.mutating, entry.mutating, entry.name)
            XCTAssertEqual(jsonRoute.output, .json, entry.name)

            let textRoute = try CLIControlRoute.classify(arguments: entry.arguments)
            XCTAssertEqual(textRoute.transport, jsonRoute.transport, entry.name)
            XCTAssertEqual(textRoute.execution, jsonRoute.execution, entry.name)
            XCTAssertEqual(textRoute.operation, jsonRoute.operation, entry.name)
            XCTAssertEqual(textRoute.subcommand, jsonRoute.subcommand, entry.name)
            XCTAssertEqual(textRoute.mutating, jsonRoute.mutating, entry.name)
            XCTAssertEqual(textRoute.output, .text, entry.name)
        }
    }

    func testDeterministicParseFailuresPreserveExitAndReasonAcrossTextAndJSON() throws {
        let arguments = ["image", "cache", "unknown-action"]
        let text = HostwrightCLI.run(arguments: arguments)
        let json = HostwrightCLI.run(arguments: arguments + ["--json"])

        XCTAssertNotEqual(text.exitCode, 0)
        XCTAssertEqual(text.exitCode, json.exitCode)
        XCTAssertTrue(text.standardError.contains(HostwrightErrorCode.commandUsage.rawValue))
        XCTAssertTrue(json.standardError.contains(HostwrightErrorCode.commandUsage.rawValue))
        XCTAssertTrue(text.standardError.contains("image cache supports"))
        XCTAssertTrue(json.standardError.contains("image cache supports"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(json.standardError.utf8)))
    }

    func testRequestValidationRejectsMetadataMismatchesAndArgumentBounds() throws {
        let route = try CLIControlRoute.classify(arguments: ["capabilities"])
        let request = request(route: route)
        XCTAssertEqual(try CLIControlRoute.validate(request: request), route)

        let mismatchedOperation = ControlRequestEnvelope(
            requestID: "request-1",
            operation: "paths",
            timeoutMilliseconds: 1_000,
            body: route.requestBody()
        )
        assertDiagnostic(.controlAPIInvalid) {
            _ = try CLIControlRoute.validate(request: mismatchedOperation)
        }

        let mismatchedMutation = ControlRequestEnvelope(
            requestID: "request-1",
            operation: route.operation,
            timeoutMilliseconds: 1_000,
            body: replacing(route.requestBody(), key: "mutating", with: .bool(true))
        )
        assertDiagnostic(.controlAPIInvalid) {
            _ = try CLIControlRoute.validate(request: mismatchedMutation)
        }

        let mismatchedSubcommand = ControlRequestEnvelope(
            requestID: "request-1",
            operation: route.operation,
            timeoutMilliseconds: 1_000,
            body: replacing(route.requestBody(), key: "subcommand", with: .string("status"))
        )
        assertDiagnostic(.controlAPIInvalid) {
            _ = try CLIControlRoute.validate(request: mismatchedSubcommand)
        }

        assertDiagnostic(.controlAPIInvalid) {
            _ = try CLIControlRoute.classify(
                arguments: Array(repeating: "help", count: CLIControlRoute.maximumArgumentCount + 1)
            )
        }
        assertDiagnostic(.controlAPIInvalid) {
            _ = try CLIControlRoute.classify(
                arguments: [String(repeating: "x", count: CLIControlRoute.maximumArgumentBytes + 1)]
            )
        }
        assertDiagnostic(.controlAPIInvalid) {
            _ = try CLIControlRoute.classify(
                arguments: [String(repeating: "x", count: CLIControlRoute.maximumCombinedArgumentBytes + 1)]
            )
        }
        assertDiagnostic(.controlAPIInvalid) {
            _ = try route.withWorkingDirectory("relative/project")
        }
        let invalidWorkingDirectory = ControlRequestEnvelope(
            requestID: "request-1",
            operation: route.operation,
            timeoutMilliseconds: 1_000,
            body: replacing(
                route.requestBody(),
                key: "workingDirectory",
                with: .string("relative/project")
            )
        )
        assertDiagnostic(.controlAPIInvalid) {
            _ = try CLIControlRoute.validate(request: invalidWorkingDirectory)
        }
    }

    func testStreamPreparationRejectsUnaryRoutesAndAcceptsClassifiedStream() throws {
        let streamRoute = try CLIControlRoute.classify(arguments: [
            "exec", "api", "--no-stdin", "--", "/bin/true",
        ])
        let streamRequest = ControlRequestEnvelope(
            requestID: "stream-1",
            operation: CLIControlStreamPreparationContract.operation,
            timeoutMilliseconds: 1_000,
            body: streamRoute.requestBody()
        )
        XCTAssertEqual(
            try CLIControlRoute.validateStreamPreparation(request: streamRequest),
            streamRoute
        )

        let unaryRoute = try CLIControlRoute.classify(arguments: ["capabilities"])
        let unaryRequest = ControlRequestEnvelope(
            requestID: "stream-2",
            operation: CLIControlStreamPreparationContract.operation,
            timeoutMilliseconds: 1_000,
            body: unaryRoute.requestBody()
        )
        assertDiagnostic(.controlAPIInvalid) {
            _ = try CLIControlRoute.validateStreamPreparation(request: unaryRequest)
        }
    }

    private func request(route: CLIControlRoute) -> ControlRequestEnvelope {
        ControlRequestEnvelope(
            requestID: "request-1",
            operation: route.operation,
            timeoutMilliseconds: 1_000,
            idempotencyKey: route.mutating ? "request-1" : nil,
            body: route.requestBody()
        )
    }

    private func replacing(
        _ body: ControlPlaneJSONValue,
        key: String,
        with value: ControlPlaneJSONValue
    ) -> ControlPlaneJSONValue {
        guard case .object(var fields) = body else {
            XCTFail("The CLI route request body must be an object.")
            return body
        }
        fields[key] = value
        return .object(fields)
    }

    private func assertDiagnostic(
        _ expectedCode: HostwrightErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? HostwrightDiagnostic)?.code, expectedCode, file: file, line: line)
        }
    }
}

private extension CLIControlRouteTests {
    struct NestedActionEntry {
        let name: String
        let arguments: [String]
        let operation: String
        let subcommand: String
        let mutating: Bool
        let jsonArguments: [String]
    }

    var nestedActionInventory: [NestedActionEntry] {
        let id = "11111111-1111-4111-8111-111111111111"
        let otherID = "22222222-2222-4222-8222-222222222222"
        let volume = "33333333-3333-4333-8333-333333333333"
        let snapshot = "44444444-4444-4444-8444-444444444444"
        let backup = "55555555-5555-4555-8555-555555555555"
        let reference = "66666666-6666-4666-8666-666666666666"
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let confirmation = String(repeating: "b", count: 64)
        func entry(
            _ name: String,
            _ arguments: [String],
            _ subcommand: String,
            _ mutating: Bool,
            jsonSuffix: [String] = ["--json"]
        ) -> NestedActionEntry {
            .init(
                name: name, arguments: arguments, operation: arguments[0], subcommand: subcommand,
                mutating: mutating, jsonArguments: arguments + jsonSuffix)
        }

        return [
            entry("runtime.providers", ["runtime", "providers"], "providers", false),
            entry("runtime.migrate", ["runtime", "migrate", "/tmp/hostwright.yaml", "--to", "apple-cli", "--dry-run"], "migrate", true),

            entry("state.integrity", ["state", "integrity"], "integrity", false),
            entry("state.backup", ["state", "backup"], "backup", true),
            entry("state.backups", ["state", "backups"], "backups", false),
            entry("state.restore", ["state", "restore", "--backup", "backup-a", "--dry-run"], "restore", true),
            entry("state.repair", ["state", "repair", "--dry-run"], "repair", true),
            entry("state.recover", ["state", "recover"], "recover", true),
            entry("state.retention", ["state", "retention", "/tmp/hostwright.yaml"], "retention", true),
            entry("state.compact", ["state", "compact", "/tmp/hostwright.yaml", "--dry-run"], "compact", true),

            entry("secret.create", ["secret", "create", "keychain://hostwright.test/api"], "create", true),
            entry("secret.update", ["secret", "update", "keychain://hostwright.test/api"], "update", true),
            entry("secret.list", ["secret", "list"], "list", false),
            entry("secret.check", ["secret", "check", "keychain://hostwright.test/api"], "check", false),
            entry("secret.delete", ["secret", "delete", "keychain://hostwright.test/api"], "delete", true),

            entry("restart-budget.status", ["restart-budget", "status"], "status", false),
            entry("restart-budget.release", ["restart-budget", "release", "--project", "project-demo", "--service", "api", "--confirm-hold", confirmation], "release", true),

            entry("maintenance.preview", ["maintenance", "preview", "/tmp/hostwright.yaml", "--action", "create"], "preview", false),
            entry("maintenance.status", ["maintenance", "status"], "status", false),
            entry("maintenance.cancel", ["maintenance", "cancel", "--project", "project-demo", "--confirm-deferral", confirmation], "cancel", true),
            entry("maintenance.override", ["maintenance", "override", "--project", "project-demo", "--confirm-deferral", confirmation, "--reason", "approved-window"], "override", true),

            entry("ownership.status", ["ownership", "status"], "status", false),
            entry("ownership.handoff", ["ownership", "handoff", "--group", id, "--confirm-plan", confirmation, "--confirm-fence", otherID, "--from-controller", "hostwright-cli:operation", "--from-expiry", "2026-08-03T00:00:00Z", "--to-controller", "resume", "--lease-seconds", "60"], "handoff", true),

            entry("metrics.snapshot", ["metrics", "snapshot"], "snapshot", false, jsonSuffix: ["--output", "json"]),
            entry("metrics.export", ["metrics", "export", "--output-path", "/tmp/metrics.json", "--confirm-snapshot", confirmation], "export", false, jsonSuffix: ["--output", "json"]),
            entry("traces.inspect", ["traces", "inspect", "--trace-id", id], "inspect", false),
            entry("traces.export", ["traces", "export", "--trace-id", id, "--output-path", "/tmp/trace.json", "--confirm-trace", confirmation], "export", false),

            entry("recovery.inspect", ["recovery"], "recovery", false, jsonSuffix: ["--output", "json"]),
            entry("recovery.resume", ["recovery", "resume", "--group", id, "--confirm-plan", confirmation], "resume", true, jsonSuffix: ["--output", "json"]),
            entry("recovery.rollback", ["recovery", "rollback", "--group", id, "--confirm-plan", confirmation], "rollback", true, jsonSuffix: ["--output", "json"]),

            entry("support.status", ["diagnostics", "support", "status"], "support.status", false),
            entry("support.preview", ["diagnostics", "support", "preview", "--project", "demo"], "support.preview", false),
            entry("support.create", ["diagnostics", "support", "create", "--output-path", "/tmp/support.tar", "--confirm-preview", confirmation], "support.create", true),
            entry("support.delete", ["diagnostics", "support", "delete", "--bundle", "/tmp/support.tar", "--confirm-bundle", confirmation], "support.delete", true),
            entry("support.recover", ["diagnostics", "support", "recover"], "support.recover", true),

            entry("registry.login", ["registry", "login", "registry.example.com", "--username", "operator"], "login", true),
            entry("registry.logout", ["registry", "logout", "registry.example.com"], "logout", true),
            entry("registry.status", ["registry", "status", "registry.example.com"], "status", false),

            entry("registry.referrers.discover", ["registry", "referrers", "discover", "registry.example.com", "--repository", "team/app", "--subject", digest], "referrers.discover", true),
            entry("registry.referrers.fetch", ["registry", "referrers", "fetch", "registry.example.com", "--repository", "team/app", "--subject", digest], "referrers.fetch", true),
            entry("registry.referrers.publish", ["registry", "referrers", "publish", id, "--target-server", "target.example.com", "--target-repository", "team/app"], "referrers.publish", true),
            entry("registry.referrers.copy", ["registry", "referrers", "copy", "registry.example.com", "--repository", "team/app", "--subject", digest, "--target-server", "target.example.com", "--target-repository", "team/copy"], "referrers.copy", true),
            entry("registry.referrers.retain", ["registry", "referrers", "retain", id, "--owner", "policy-a", "--expires-at", "2026-12-31T00:00:00Z"], "referrers.retain", true),
            entry("registry.referrers.release", ["registry", "referrers", "release", id, "--fencing-token", otherID], "referrers.release", true),
            entry("registry.referrers.status", ["registry", "referrers", "status", id], "referrers.status", false),
            entry("registry.referrers.prune", ["registry", "referrers", "prune", id, "--digest", digest], "referrers.prune", true),
            entry("registry.referrers.resume", ["registry", "referrers", "resume", id, "--confirm-plan", confirmation], "referrers.resume", true),

            entry("registry.trust.verify", ["registry", "trust", "verify", id, "--manifest", "/tmp/hostwright.yaml", "--subject-manifest", "/tmp/subject.json", "--cosign", "/usr/bin/true"], "trust.verify", true),
            entry("registry.trust.status", ["registry", "trust", "status", "/tmp/hostwright.yaml"], "trust.status", false),
            entry("registry.trust.grant-exception", ["registry", "trust", "grant-exception", "/tmp/approval.json", "--manifest", "/tmp/hostwright.yaml"], "trust.grant-exception", true),
            entry("registry.trust.revoke-exception", ["registry", "trust", "revoke-exception", id], "trust.revoke-exception", true),

            entry("registry.sbom.generate", ["registry", "sbom", "generate", "/tmp/image.oci", "--manifest", "/tmp/hostwright.yaml", "--server", "registry.example.com", "--repository", "team/app", "--format", "spdx-json"], "sbom.generate", true),
            entry("registry.sbom.ingest", ["registry", "sbom", "ingest", id, "--manifest", "/tmp/hostwright.yaml"], "sbom.ingest", true),
            entry("registry.sbom.query", ["registry", "sbom", "query", "/tmp/hostwright.yaml"], "sbom.query", false),
            entry("registry.sbom.export", ["registry", "sbom", "export", "/tmp/hostwright.yaml", "--format", "spdx-json", "--output-path", "/tmp/image.sbom.json"], "sbom.export", true),
            entry("registry.sbom.resume", ["registry", "sbom", "resume", id, "--confirm-plan", confirmation], "sbom.resume", true),

            entry("registry.vulnerability.evaluate", ["registry", "vulnerability", "evaluate", id, "--digest", digest, "--manifest", "/tmp/hostwright.yaml", "--cosign", "/usr/bin/true"], "vulnerability.evaluate", true),
            entry("registry.vulnerability.status", ["registry", "vulnerability", "status", "/tmp/hostwright.yaml"], "vulnerability.status", false),
            entry("registry.vulnerability.grant-exception", ["registry", "vulnerability", "grant-exception", "/tmp/approval.json", "--manifest", "/tmp/hostwright.yaml"], "vulnerability.grant-exception", true),
            entry("registry.vulnerability.revoke-exception", ["registry", "vulnerability", "revoke-exception", id], "vulnerability.revoke-exception", true),
            entry("registry.vulnerability.resume", ["registry", "vulnerability", "resume", id, "--confirm-plan", confirmation], "vulnerability.resume", true),

            entry("registry.provenance.generate", ["registry", "provenance", "generate", "/tmp/image.tar", "--record", "/tmp/record.json", "--manifest", "/tmp/hostwright.yaml", "--server", "registry.example.com", "--repository", "team/app", "--signer", "release-builder", "--signing-key-ref", "keychain://hostwright.provenance/release"], "provenance.generate", true),
            entry("registry.provenance.verify", ["registry", "provenance", "verify", id, "--digest", digest, "--manifest", "/tmp/hostwright.yaml"], "provenance.verify", true),
            entry("registry.provenance.status", ["registry", "provenance", "status", "/tmp/hostwright.yaml"], "provenance.status", false),
            entry("registry.provenance.resume", ["registry", "provenance", "resume", id, "--confirm-plan", confirmation], "provenance.resume", true),

            entry("image.inspect", ["image", "inspect", "registry.example.com/team/app:v1"], "inspect", false),
            entry("image.pull", ["image", "pull", "registry.example.com/team/app:v1"], "pull", true),
            entry("image.push", ["image", "push", "registry.example.com/team/app:v1"], "push", true),
            entry("image.tag", ["image", "tag", "registry.example.com/team/app:v1", "registry.example.com/team/app:stable"], "tag", true),
            entry("image.load", ["image", "load", "--input", "/tmp/image.oci", "--reference", "registry.example.com/team/app:v1"], "load", true),
            entry("image.save", ["image", "save", "registry.example.com/team/app:v1", "--output", "/tmp/image.oci"], "save", true),
            entry("image.build", ["image", "build", "--context", "/tmp/context", "--tag", "registry.example.com/team/app:v1"], "build", true),
            entry("image.delete", ["image", "delete", "registry.example.com/team/app:v1"], "delete", true),
            entry("image.prune", ["image", "prune", "--dry-run"], "prune", true),
            entry("image.cache.status", ["image", "cache", "status"], "cache.status", false),
            entry("image.cache.pin", ["image", "cache", "pin", "registry.example.com/team/app:v1"], "cache.pin", true),
            entry("image.cache.unpin", ["image", "cache", "unpin", "registry.example.com/team/app:v1"], "cache.unpin", true),

            entry("volume.list", ["volume", "list"], "list", false),
            entry("volume.inspect", ["volume", "inspect", volume], "inspect", false),
            entry("volume.capacity", ["volume", "capacity"], "capacity", false),
            entry("volume.health", ["volume", "health"], "health", false),
            entry("volume.recover", ["volume", "recover", volume, "--idempotency-key", "recovery-a"], "recover", true),
            entry("volume.delete", ["volume", "delete", volume, "--dry-run"], "delete", true),
            entry("volume.prune", ["volume", "prune", "--dry-run"], "prune", true),
            entry("volume.snapshot.create", ["volume", "snapshot", "create", volume, "--snapshot-id", snapshot, "--name", "daily"], "snapshot.create", true),
            entry("volume.snapshot.list", ["volume", "snapshot", "list", volume], "snapshot.list", false),
            entry("volume.snapshot.inspect", ["volume", "snapshot", "inspect", volume, snapshot], "snapshot.inspect", false),
            entry("volume.snapshot.retain", ["volume", "snapshot", "retain", volume, snapshot, "--owner", "policy-a"], "snapshot.retain", true),
            entry("volume.snapshot.export", ["volume", "snapshot", "export", volume, snapshot, "--output", "/tmp/snapshot.tar"], "snapshot.export", true),
            entry("volume.snapshot.restore", ["volume", "snapshot", "restore", snapshot, "--source-volume", volume, "--to-volume", otherID, "--reference-id", reference, "--dry-run"], "snapshot.restore", true),
            entry("volume.snapshot.delete", ["volume", "snapshot", "delete", volume, snapshot, "--dry-run"], "snapshot.delete", true),
            entry("volume.backup.create", ["volume", "backup", "create", "--volume", volume, "--backup-id", backup, "--name", "nightly", "--key-ref", "keychain://hostwright/backup"], "backup.create", true),
            entry("volume.backup.list", ["volume", "backup", "list", volume], "backup.list", false),
            entry("volume.backup.inspect", ["volume", "backup", "inspect", volume, backup], "backup.inspect", false),
            entry("volume.backup.verify", ["volume", "backup", "verify", volume, backup, "--key-ref", "keychain://hostwright/backup"], "backup.verify", false),
            entry("volume.backup.retain", ["volume", "backup", "retain", volume, backup, "--owner", "policy-a"], "backup.retain", true),
            entry("volume.backup.restore", ["volume", "backup", "restore", backup, "--key-ref", "keychain://hostwright/backup", "--target", "\(volume)=\(otherID)", "--dry-run"], "backup.restore", true),
            entry("volume.backup.delete", ["volume", "backup", "delete", volume, backup, "--dry-run"], "backup.delete", true),
        ]
    }

    struct FrozenInventoryEntry {
        let command: String
        let arguments: [String]
        let transport: CLIControlTransportKind
    }

    var frozenInventory: [FrozenInventoryEntry] {
        let dryRun = ["--dry-run"]
        let lifecycle = ["hostwright.yaml", "--dry-run"]
        return [
            .init(command: "version", arguments: ["version"], transport: .localPresentation),
            .init(command: "help", arguments: ["help"], transport: .localPresentation),
            .init(command: "capabilities", arguments: ["capabilities"], transport: .persistentControlAPI),
            .init(command: "observability", arguments: ["observability", "status"], transport: .persistentControlAPI),
            .init(command: "runtime", arguments: ["runtime", "providers"], transport: .persistentControlAPI),
            .init(command: "paths", arguments: ["paths"], transport: .persistentControlAPI),
            .init(command: "state", arguments: ["state", "integrity"], transport: .persistentControlAPI),
            .init(command: "secret", arguments: ["secret", "list"], transport: .persistentControlAPI),
            .init(command: "registry", arguments: ["registry", "status", "registry.example"], transport: .persistentControlAPI),
            .init(command: "image", arguments: ["image", "inspect", "alpine:3.20"], transport: .persistentControlAPI),
            .init(command: "volume", arguments: ["volume", "list"], transport: .persistentControlAPI),
            .init(command: "daemon.status", arguments: ["daemon", "status"], transport: .persistentControlAPI),
            .init(command: "daemon.install", arguments: ["daemon", "install", "--daemon-executable", "/usr/local/bin/hostwrightd", "--config", "/etc/hostwrightd.json"], transport: .bootstrapAPI),
            .init(command: "daemon.validate", arguments: ["daemon", "validate"], transport: .persistentControlAPI),
            .init(command: "daemon.bootstrap", arguments: ["daemon", "bootstrap"], transport: .persistentControlAPI),
            .init(command: "daemon.start", arguments: ["daemon", "start"], transport: .persistentControlAPI),
            .init(command: "daemon.stop", arguments: ["daemon", "stop"], transport: .persistentControlAPI),
            .init(command: "daemon.kickstart", arguments: ["daemon", "kickstart"], transport: .persistentControlAPI),
            .init(command: "daemon.upgrade", arguments: ["daemon", "upgrade", "--daemon-executable", "/usr/local/bin/hostwrightd", "--config", "/etc/hostwrightd.json"], transport: .persistentControlAPI),
            .init(command: "daemon.rollback", arguments: ["daemon", "rollback"], transport: .persistentControlAPI),
            .init(command: "daemon.disable", arguments: ["daemon", "disable"], transport: .persistentControlAPI),
            .init(command: "daemon.repair", arguments: ["daemon", "repair"], transport: .bootstrapAPI),
            .init(command: "daemon.uninstall", arguments: ["daemon", "uninstall"], transport: .bootstrapAPI),
            .init(command: "restart-budget", arguments: ["restart-budget", "status"], transport: .persistentControlAPI),
            .init(command: "maintenance", arguments: ["maintenance", "status"], transport: .persistentControlAPI),
            .init(command: "ownership", arguments: ["ownership", "status"], transport: .persistentControlAPI),
            .init(command: "metrics", arguments: ["metrics", "snapshot"], transport: .persistentControlAPI),
            .init(command: "traces", arguments: ["traces", "inspect"], transport: .persistentControlAPI),
            .init(command: "migrate", arguments: ["migrate", "preview", "hostwright.yaml"], transport: .persistentControlAPI),
            .init(command: "init", arguments: ["init"], transport: .persistentControlAPI),
            .init(command: "import-stack", arguments: ["import-stack", "compose.yaml"], transport: .persistentControlAPI),
            .init(command: "export-stack", arguments: ["export-stack", "hostwright.yaml"], transport: .persistentControlAPI),
            .init(command: "plan-stack-update", arguments: ["plan-stack-update", "current.yaml", "desired.yaml"], transport: .persistentControlAPI),
            .init(command: "validate", arguments: ["validate", "hostwright.yaml"], transport: .persistentControlAPI),
            .init(command: "plan", arguments: ["plan", "hostwright.yaml"], transport: .persistentControlAPI),
            .init(command: "status", arguments: ["status", "hostwright.yaml"], transport: .persistentControlAPI),
            .init(command: "apply", arguments: ["apply", "hostwright.yaml", "--confirm-plan", String(repeating: "a", count: 64)], transport: .persistentControlAPI),
            .init(command: "up", arguments: ["up"] + lifecycle, transport: .persistentControlAPI),
            .init(command: "down", arguments: ["down"] + lifecycle, transport: .persistentControlAPI),
            .init(command: "run", arguments: ["run", "--service", "api"] + lifecycle, transport: .persistentControlAPI),
            .init(command: "start", arguments: ["start"] + lifecycle, transport: .persistentControlAPI),
            .init(command: "stop", arguments: ["stop"] + lifecycle, transport: .persistentControlAPI),
            .init(command: "restart", arguments: ["restart"] + lifecycle, transport: .persistentControlAPI),
            .init(command: "rm", arguments: ["rm"] + lifecycle, transport: .persistentControlAPI),
            .init(command: "update", arguments: ["update"] + lifecycle, transport: .persistentControlAPI),
            .init(command: "exec", arguments: ["exec", "api", "--no-stdin", "--", "/bin/true"], transport: .persistentControlAPI),
            .init(command: "attach", arguments: ["attach", "api"], transport: .persistentControlAPI),
            .init(command: "copy", arguments: ["copy", "/tmp/input", "api:/tmp/output"], transport: .persistentControlAPI),
            .init(command: "export", arguments: ["export", "api", "/tmp/export.tar"], transport: .persistentControlAPI),
            .init(command: "inspect", arguments: ["inspect", "api"], transport: .persistentControlAPI),
            .init(command: "stats", arguments: ["stats", "api"], transport: .persistentControlAPI),
            .init(command: "logs", arguments: ["logs", "api"], transport: .persistentControlAPI),
            .init(command: "events", arguments: ["events"], transport: .persistentControlAPI),
            .init(command: "recovery", arguments: ["recovery"], transport: .persistentControlAPI),
            .init(command: "cleanup", arguments: ["cleanup"] + dryRun, transport: .persistentControlAPI),
            .init(command: "diagnostics", arguments: ["diagnostics", "--bundle", "/tmp/support.zip"], transport: .persistentControlAPI),
            .init(command: "benchmark", arguments: ["benchmark", "--image", "alpine:3.20", "--samples", "3", "--report", "/tmp/benchmark.json", "--source-commit", String(repeating: "a", count: 40), "--source-dirty", "false", "--expected-container-version", "1.0.0", "--confirm-live"], transport: .persistentControlAPI),
            .init(command: "extension", arguments: ["extension", "check", "--declaration", "/tmp/extension.json", "--executable", "/usr/bin/true"], transport: .persistentControlAPI),
            .init(command: "doctor", arguments: ["doctor"], transport: .persistentControlAPI),
        ]
    }
}

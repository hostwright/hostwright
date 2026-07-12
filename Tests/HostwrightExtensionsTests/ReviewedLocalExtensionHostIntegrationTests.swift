import CryptoKit
import Darwin
import Foundation
import HostwrightCore
@testable import HostwrightExtensions
import HostwrightPolicy
import XCTest

final class ReviewedLocalExtensionHostIntegrationTests: XCTestCase {
    private var fixtureRoot: URL?
    private var fixtureURL: URL?
    private var fixtureSHA256: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-extension-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let executable = root.appendingPathComponent("extension-fixture", isDirectory: false)
        try Self.compileFixture(to: executable)
        fixtureRoot = root
        fixtureURL = executable
        fixtureSHA256 = try Self.sha256(executable)
    }

    override func tearDownWithError() throws {
        if let root = fixtureRoot {
            try FileManager.default.removeItem(at: root)
        }
        fixtureRoot = nil
        fixtureURL = nil
        fixtureSHA256 = nil
        try super.tearDownWithError()
    }

    func testRealCompiledExtensionCompletesExactBoundHandshakeAndCleanup() throws {
        let fixture = try requireFixture()
        let workspace = try makeWorkspace(identifier: "dev.hostwright.integration", executableSHA256: fixture.sha256)
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let executableBefore = try Self.sha256(fixture.url)

        let result = try host(for: workspace, timeoutMilliseconds: 2_000).check(
            declarationURL: workspace.declaration,
            executableURL: fixture.url
        )

        XCTAssertEqual(result.identifier, "dev.hostwright.integration")
        XCTAssertEqual(result.capability, .diagnosticsRead)
        XCTAssertEqual(result.protocolVersion, 1)
        XCTAssertEqual(result.executableSHA256, fixture.sha256)
        XCTAssertEqual(result.declarationSHA256.count, 64)
        XCTAssertGreaterThanOrEqual(result.durationMilliseconds, 0)
        XCTAssertTrue(result.cleanupSucceeded)
        XCTAssertEqual(try stagingEntries(workspace), [])
        XCTAssertEqual(try Self.sha256(fixture.url), executableBefore)
    }

    func testRealProcessesFailClosedForTimeoutOverflowExitAndResponseViolations() throws {
        let fixture = try requireFixture()
        let cases: [(suffix: String, timeout: Int, outputLimit: Int)] = [
            ("timeout", 100, 64 * 1_024),
            ("overflow", 2_000, 1_024),
            ("failure", 2_000, 64 * 1_024),
            ("malformed", 2_000, 64 * 1_024),
            ("duplicate", 2_000, 64 * 1_024),
            ("extra", 2_000, 64 * 1_024),
            ("mismatch", 2_000, 64 * 1_024),
            ("stderr", 2_000, 64 * 1_024)
        ]

        for item in cases {
            let workspace = try makeWorkspace(
                identifier: "dev.hostwright.integration.\(item.suffix)",
                executableSHA256: fixture.sha256
            )
            defer { try? FileManager.default.removeItem(at: workspace.root) }

            assertDiagnostic(
                tryRun: {
                    try host(
                        for: workspace,
                        timeoutMilliseconds: item.timeout,
                        maximumOutputBytes: item.outputLimit
                    ).check(declarationURL: workspace.declaration, executableURL: fixture.url)
                },
                code: .extensionExecutionFailed
            ) {
                XCTAssertFalse($0.message.contains("fixture-secret-must-not-leak"))
            }
            XCTAssertEqual(try stagingEntries(workspace), [], "staging leak for \(item.suffix)")
        }
    }

    func testDigestMismatchFailsBeforeExecutionAndStillCleansStaging() throws {
        let fixture = try requireFixture()
        let workspace = try makeWorkspace(
            identifier: "dev.hostwright.integration",
            executableSHA256: String(repeating: "a", count: 64)
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        assertDiagnostic(
            tryRun: {
                try host(for: workspace).check(
                    declarationURL: workspace.declaration,
                    executableURL: fixture.url
                )
            },
            code: .extensionInvalid
        )
        XCTAssertEqual(try stagingEntries(workspace), [])
    }

    func testPolicyBlockerPreventsProcessLaunch() throws {
        let fixture = try requireFixture()
        let workspace = try makeWorkspace(
            identifier: "dev.hostwright.integration",
            executableSHA256: fixture.sha256,
            boundaries: [.redaction]
        )
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        assertDiagnostic(
            tryRun: {
                try host(for: workspace).check(
                    declarationURL: workspace.declaration,
                    executableURL: fixture.url
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains(PolicyReasonCode.extensionBoundaryMissing.rawValue))
        }
        XCTAssertEqual(try stagingEntries(workspace), [])
    }

    func testHostRejectsSymlinksAndUnsafeWriteModes() throws {
        let fixture = try requireFixture()
        let workspace = try makeWorkspace(identifier: "dev.hostwright.integration", executableSHA256: fixture.sha256)
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let declarationLink = workspace.root.appendingPathComponent("declaration-link.json")
        try FileManager.default.createSymbolicLink(at: declarationLink, withDestinationURL: workspace.declaration)
        assertDiagnostic(
            tryRun: { try host(for: workspace).check(declarationURL: declarationLink, executableURL: fixture.url) },
            code: .extensionInvalid
        )

        let executableLink = workspace.root.appendingPathComponent("executable-link")
        try FileManager.default.createSymbolicLink(at: executableLink, withDestinationURL: fixture.url)
        assertDiagnostic(
            tryRun: { try host(for: workspace).check(declarationURL: workspace.declaration, executableURL: executableLink) },
            code: .extensionInvalid
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: workspace.declaration.path)
        assertDiagnostic(
            tryRun: { try host(for: workspace).check(declarationURL: workspace.declaration, executableURL: fixture.url) },
            code: .extensionBlocked
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspace.declaration.path)

        let unsafeExecutable = workspace.root.appendingPathComponent("unsafe-executable")
        try FileManager.default.copyItem(at: fixture.url, to: unsafeExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafeExecutable.path)
        assertDiagnostic(
            tryRun: { try host(for: workspace).check(declarationURL: workspace.declaration, executableURL: unsafeExecutable) },
            code: .extensionBlocked
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o4700], ofItemAtPath: unsafeExecutable.path)
        assertDiagnostic(
            tryRun: { try host(for: workspace).check(declarationURL: workspace.declaration, executableURL: unsafeExecutable) },
            code: .extensionBlocked
        )

        let nonExecutable = workspace.root.appendingPathComponent("non-executable")
        try FileManager.default.copyItem(at: fixture.url, to: nonExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nonExecutable.path)
        assertDiagnostic(
            tryRun: { try host(for: workspace).check(declarationURL: workspace.declaration, executableURL: nonExecutable) },
            code: .extensionInvalid
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: workspace.staging.path)
        assertDiagnostic(
            tryRun: { try host(for: workspace).check(declarationURL: workspace.declaration, executableURL: fixture.url) },
            code: .extensionExecutionFailed
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.staging.path)
        XCTAssertEqual(try stagingEntries(workspace), [])
    }

    private func host(
        for workspace: Workspace,
        timeoutMilliseconds: Int = 2_000,
        maximumOutputBytes: Int = 64 * 1_024
    ) -> ReviewedLocalExtensionHost {
        ReviewedLocalExtensionHost(
            configuration: ExtensionHostConfiguration(
                timeoutMilliseconds: timeoutMilliseconds,
                maximumOutputBytes: maximumOutputBytes,
                stagingRootURL: workspace.staging
            )
        )
    }

    private func makeWorkspace(
        identifier: String,
        executableSHA256: String,
        boundaries: [HostwrightExtensionBoundary] = [
            .stateStore,
            .explicitStatePath,
            .redaction,
            .auditTrail,
            .localOnlyNoUpload,
            .noRuntimeMutation
        ]
    ) throws -> Workspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-extension-host-tests-\(UUID().uuidString)", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)

        let declaration = root.appendingPathComponent("extension.json")
        let document = ExecutableExtensionDocument(
            kind: .diagnosticsIntegration,
            identifier: identifier,
            trust: .reviewedLocal,
            capability: .diagnosticsRead,
            purpose: "Exercise the real reviewed-local subprocess handshake.",
            boundaries: boundaries,
            executableSHA256: executableSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (try encoder.encode(document) + Data("\n".utf8)).write(to: declaration, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: declaration.path)
        return Workspace(root: root, staging: staging, declaration: declaration)
    }

    private func stagingEntries(_ workspace: Workspace) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspace.staging.path).sorted()
    }

    private func requireFixture() throws -> (url: URL, sha256: String) {
        (
            try XCTUnwrap(fixtureURL, "fixture executable was not compiled"),
            try XCTUnwrap(fixtureSHA256, "fixture digest was not computed")
        )
    }

    private func assertDiagnostic<T>(
        tryRun: () throws -> T,
        code: HostwrightErrorCode,
        inspect: (HostwrightDiagnostic) -> Void = { _ in }
    ) {
        XCTAssertThrowsError(try tryRun()) { error in
            guard let diagnostic = error as? HostwrightDiagnostic else {
                return XCTFail("Expected HostwrightDiagnostic, got \(error)")
            }
            XCTAssertEqual(diagnostic.code.rawValue, code.rawValue)
            inspect(diagnostic)
        }
    }

    private static func compileFixture(to outputURL: URL) throws {
        let sourceURL = try XCTUnwrap(
            Bundle.module.url(forResource: "ExtensionFixture", withExtension: "swift")
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        process.arguments = [sourceURL.path, "-o", outputURL.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HostwrightDiagnostic(
                code: .extensionExecutionFailed,
                message: "swiftc failed to compile the extension fixture with exit \(process.terminationStatus)."
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputURL.path)
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct Workspace {
    let root: URL
    let staging: URL
    let declaration: URL
}

import Darwin
import Foundation
import XCTest
@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore

final class BootstrapControlClientTests: XCTestCase {
    func testSpawnedProcessValidationBindsTheActualRunningCodeIdentity() throws {
        let identity = try BootstrapControlClient.spawnedCodeIdentity(processID: getpid())
        XCTAssertNoThrow(try BootstrapControlClient.validateSpawnedCompanion(
            processID: getpid(),
            expectedIdentity: identity
        ))
        let replacement = identity.codeDirectoryHash.first == "0" ? "1" : "0"
        let changedHash = replacement + identity.codeDirectoryHash.dropFirst()
        let changed = CodeIdentity(
            teamIdentifier: identity.teamIdentifier,
            signingIdentifier: identity.signingIdentifier,
            codeDirectoryHash: changedHash,
            validationMode: identity.validationMode
        )
        XCTAssertThrowsError(try BootstrapControlClient.validateSpawnedCompanion(
            processID: getpid(),
            expectedIdentity: changed
        )) { error in
            XCTAssertEqual(error as? BootstrapControlClientError, .unsafeCompanion)
        }
    }

    func testCompanionPreflightRejectsRelativeNonCanonicalAndMissingPaths() {
        assertUnsafeCompanion(path: "hostwright-control")
        assertUnsafeCompanion(path: "/tmp/../tmp/hostwright-control")
        assertUnsafeCompanion(path: "/private/var/tmp/hostwright-bootstrap-client-missing")
    }

    func testCompanionPreflightRejectsSymlinkBeforeCodeIdentityValidation() throws {
        let root = try makeOwnedRoot()
        defer { removeOwnedRoot(root) }
        let link = root.appendingPathComponent(BootstrapControlClient.companionName)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/usr/bin/true"
        )

        assertUnsafeCompanion(path: link.path)
    }

    func testDefaultCompanionPathIsAbsoluteAndUsesTheFixedCompanionName() throws {
        let path = try BootstrapControlClient.defaultCompanionPath()
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, BootstrapControlClient.companionName)
        XCTAssertEqual(URL(fileURLWithPath: path).standardizedFileURL.path, path)
    }

    func testAdHocSourceIdentifiersAcceptOnlyExactBaseOrSwiftPMSuffix() {
        XCTAssertTrue(BootstrapControlClient.isAdHocSourceIdentifier(
            "hostwright-control",
            base: "hostwright-control"
        ))
        XCTAssertTrue(BootstrapControlClient.isAdHocSourceIdentifier(
            "hostwright-control-" + String(repeating: "a", count: 40),
            base: "hostwright-control"
        ))
        for invalid in [
            "hostwright-control-" + String(repeating: "a", count: 39),
            "hostwright-control-" + String(repeating: "A", count: 40),
            "other-" + String(repeating: "a", count: 40),
        ] {
            XCTAssertFalse(BootstrapControlClient.isAdHocSourceIdentifier(
                invalid,
                base: "hostwright-control"
            ))
        }
    }

    func testBoundedSubprocessRequestUsesPinnedIdentityAndReturnsValidatedResponse() throws {
        let request = try makeRequest(requestID: "bootstrap-success")
        let responseData = try ControlPlaneCanonicalJSON.encode(
            ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: try CLIControlResultContract.value(
                    CLIRunResult(standardOutput: "ok\n", standardError: "", exitCode: 0)
                )
            )
        )
        let capture = SubprocessCapture(
            result: result(standardOutput: responseData)
        )
        let identity = fixtureIdentity()
        let client = BootstrapControlClient(
            testingCompanionPath: identity.path,
            identity: identity,
            runSubprocess: capture.run
        )

        let response = try client.send(request)

        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.status, .completed)
        let invocation = try XCTUnwrap(capture.invocation)
        XCTAssertEqual(invocation.request.executablePath, identity.path)
        XCTAssertEqual(invocation.identity, identity)
        XCTAssertEqual(invocation.request.arguments, ["--bootstrap"])
        XCTAssertEqual(invocation.request.standardInput, try ControlPlaneCanonicalJSON.encode(request))
        XCTAssertEqual(
            invocation.request.maximumStandardOutputBytes,
            ControlPlaneContract.maximumResponseOrFrameBytes
        )
        XCTAssertEqual(
            invocation.request.maximumStandardErrorBytes,
            ControlPlaneContract.maximumRequestBytes
        )
        XCTAssertEqual(
            invocation.request.maximumStandardInputBytes,
            ControlPlaneContract.maximumRequestBytes
        )
        XCTAssertEqual(invocation.request.terminationGraceMilliseconds, 1_000)
        XCTAssertEqual(invocation.request.workingDirectory, "/")
    }

    func testNonzeroExitStandardErrorAndMismatchedRequestIDFailClosed() throws {
        let request = try makeRequest(requestID: "bootstrap-invalid")
        let validData = try ControlPlaneCanonicalJSON.encode(
            ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed
            )
        )
        for subprocessResult in [
            result(exitStatus: 7, standardOutput: validData),
            result(standardOutput: validData, standardError: Data("unexpected".utf8)),
            result(
                standardOutput: try ControlPlaneCanonicalJSON.encode(
                    ControlResponseEnvelope(
                        requestID: "different-request",
                        status: .completed,
                        reasonCode: .completed
                    )
                )
            ),
        ] {
            let capture = SubprocessCapture(result: subprocessResult)
            let identity = fixtureIdentity()
            let client = BootstrapControlClient(
                testingCompanionPath: identity.path,
                identity: identity,
                runSubprocess: capture.run
            )
            XCTAssertThrowsError(try client.send(request)) { error in
                XCTAssertEqual(error as? BootstrapControlClientError, .invalidResponse)
            }
        }
    }

    func testTimeoutOverflowAndPinnedExecutableChangeHaveStableFailures() throws {
        let request = try makeRequest(requestID: "bootstrap-errors")
        let cases: [(SecureSubprocessError, BootstrapControlClientError)] = [
            (.timedOut(result()), .deadlineExceeded),
            (.outputLimitExceeded(result()), .invalidResponse),
            (.executableChanged, .unsafeCompanion),
        ]
        for (subprocessError, expected) in cases {
            let identity = fixtureIdentity()
            let client = BootstrapControlClient(
                testingCompanionPath: identity.path,
                identity: identity,
                runSubprocess: { _, _ in throw subprocessError }
            )
            XCTAssertThrowsError(try client.send(request)) { error in
                XCTAssertEqual(error as? BootstrapControlClientError, expected)
            }
        }
    }

    private func assertUnsafeCompanion(
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try BootstrapControlClient.validateCompanion(path: path),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? BootstrapControlClientError, .unsafeCompanion, file: file, line: line)
        }
    }

    private func makeRequest(requestID: String) throws -> ControlRequestEnvelope {
        let route = try CLIControlRoute.classify(arguments: ["daemon", "repair"])
            .withWorkingDirectory("/client/project")
        return ControlRequestEnvelope(
            requestID: requestID,
            operation: route.operation,
            timeoutMilliseconds: 1_000,
            idempotencyKey: requestID,
            body: route.requestBody()
        )
    }

    private func fixtureIdentity() -> SecureExecutableIdentity {
        SecureExecutableIdentity(
            path: "/usr/bin/true",
            device: 1,
            inode: 2,
            ownerUserID: 0,
            mode: 0o755,
            sizeBytes: 3,
            modifiedSeconds: 4,
            modifiedNanoseconds: 5,
            changedSeconds: 6,
            changedNanoseconds: 7,
            ownershipPolicy: .rootOrCurrentUser
        )
    }

    private func result(
        exitStatus: Int32 = 0,
        standardOutput: Data = Data(),
        standardError: Data = Data()
    ) -> SecureSubprocessResult {
        SecureSubprocessResult(
            exitStatus: exitStatus,
            terminationSignal: nil,
            standardOutput: standardOutput,
            standardError: standardError,
            durationMilliseconds: 1,
            standardOutputTruncated: false,
            standardErrorTruncated: false
        )
    }

    private func makeOwnedRoot() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let identifier = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let root = repository.appendingPathComponent(
            ".build/p09bc-\(identifier.prefix(12))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func removeOwnedRoot(_ root: URL) {
        guard root.path.contains("/.build/p09bc-"),
              root.lastPathComponent.range(of: "^p09bc-[a-f0-9]{12}$", options: .regularExpression) != nil,
              (try? FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?
                .intValue == 0o700 else {
            return
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SubprocessCapture: @unchecked Sendable {
    struct Invocation {
        let request: SecureSubprocessRequest
        let identity: SecureExecutableIdentity
    }

    private let lock = NSLock()
    private let result: SecureSubprocessResult
    private(set) var invocation: Invocation?

    init(result: SecureSubprocessResult) {
        self.result = result
    }

    func run(
        request: SecureSubprocessRequest,
        identity: SecureExecutableIdentity
    ) throws -> SecureSubprocessResult {
        lock.lock()
        invocation = Invocation(request: request, identity: identity)
        lock.unlock()
        return result
    }
}

import Darwin
import Foundation
import HostwrightCore
import XCTest

final class SecureSubprocessTests: XCTestCase {
    func testExactArgumentsDoNotInvokeShellExpansion() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unexpected = root.appendingPathComponent("unexpected")
        let literal = "$(touch \(unexpected.path))"

        let result = try SecureSubprocessRunner().run(
            SecureSubprocessRequest(
                executablePath: "/usr/bin/printf",
                arguments: ["%s", literal]
            )
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), literal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unexpected.path))
    }

    func testEnvironmentIsExactAndDoesNotInheritParentSecrets() throws {
        let name = "HOSTWRIGHT_PARENT_ONLY_SECRET"
        setenv(name, "must-not-cross-boundary", 1)
        defer { unsetenv(name) }

        let result = try SecureSubprocessRunner().run(
            SecureSubprocessRequest(executablePath: "/usr/bin/printenv")
        )
        let output = String(decoding: result.standardOutput, as: UTF8.self)

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(output.contains("PATH=\(SecureSubprocessEnvironment.trustedSystemPath)"))
        XCTAssertTrue(output.contains("LANG=C"))
        XCTAssertFalse(output.contains(name))
        XCTAssertFalse(output.contains("must-not-cross-boundary"))
    }

    func testShellExecutablesAreRejectedBeforeLaunch() {
        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(executablePath: "/bin/sh", arguments: ["-c", "exit 0"])
            )
        ) { error in
            XCTAssertEqual(
                error as? SecureSubprocessError,
                .executableRejected(.interpreterExecutable)
            )
        }
    }

    func testOutputFloodIsBoundedAndTerminated() {
        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: "/usr/bin/yes",
                    timeoutMilliseconds: 5_000,
                    terminationGraceMilliseconds: 50,
                    maximumStandardOutputBytes: 4_096,
                    maximumStandardErrorBytes: 4_096
                )
            )
        ) { error in
            guard case .outputLimitExceeded(let result) = error as? SecureSubprocessError else {
                return XCTFail("Expected outputLimitExceeded, received \(error)")
            }
            XCTAssertEqual(result.standardOutput.count, 4_096)
            XCTAssertTrue(result.standardOutputTruncated)
            XCTAssertLessThan(result.durationMilliseconds, 2_000)
        }
    }

    func testStandardErrorFloodIsBoundedAndTerminated() throws {
        let fixture = try makeCompiledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: fixture.executable.path,
                    arguments: ["flood-stderr"],
                    timeoutMilliseconds: 5_000,
                    terminationGraceMilliseconds: 50,
                    maximumStandardOutputBytes: 4_096,
                    maximumStandardErrorBytes: 4_096
                )
            )
        ) { error in
            guard case .outputLimitExceeded(let result) = error as? SecureSubprocessError else {
                return XCTFail("Expected outputLimitExceeded, received \(error)")
            }
            XCTAssertEqual(result.standardError.count, 4_096)
            XCTAssertTrue(result.standardErrorTruncated)
            XCTAssertLessThan(result.durationMilliseconds, 2_000)
        }
    }

    func testBoundedStandardInputRoundTripsWithoutTruncation() throws {
        let fixture = try makeCompiledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let input = Data((0..<(512 * 1_024)).map { UInt8($0 % 251) })

        let result = try SecureSubprocessRunner().run(
            SecureSubprocessRequest(
                executablePath: fixture.executable.path,
                arguments: ["echo-stdin"],
                standardInput: input,
                timeoutMilliseconds: 5_000,
                maximumStandardOutputBytes: 1 * 1_024 * 1_024,
                maximumStandardInputBytes: 1 * 1_024 * 1_024
            )
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.standardOutput, input)
        XCTAssertFalse(result.standardOutputTruncated)
    }

    func testEarlyStandardInputClosureFailsWithBoundedTypedError() throws {
        let fixture = try makeCompiledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let input = Data(repeating: 65, count: 4 * 1_024 * 1_024)

        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: fixture.executable.path,
                    arguments: ["close-stdin"],
                    standardInput: input,
                    timeoutMilliseconds: 5_000,
                    terminationGraceMilliseconds: 50,
                    maximumStandardInputBytes: input.count
                )
            )
        ) { error in
            guard case .inputWriteFailed(let result) = error as? SecureSubprocessError else {
                return XCTFail("Expected inputWriteFailed, received \(error)")
            }
            XCTAssertLessThan(result.durationMilliseconds, 2_000)
        }
    }

    func testUnrelatedFileDescriptorsAreClosedAcrossExec() throws {
        let fixture = try makeCompiledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inheritedCandidate = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThan(inheritedCandidate, STDERR_FILENO)
        defer { close(inheritedCandidate) }
        XCTAssertEqual(fcntl(inheritedCandidate, F_SETFD, 0), 0)
        let highInheritedCandidate = fcntl(inheritedCandidate, F_DUPFD, 1_024)
        XCTAssertGreaterThanOrEqual(highInheritedCandidate, 1_024)
        defer { if highInheritedCandidate >= 0 { close(highInheritedCandidate) } }
        XCTAssertEqual(fcntl(highInheritedCandidate, F_SETFD, 0), 0)

        let result = try SecureSubprocessRunner().run(
            SecureSubprocessRequest(
                executablePath: fixture.executable.path,
                arguments: ["list-fds"]
            )
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.standardOutput, Data())
    }

    func testWorkingDirectoryUsesVerifiedDirectoryDescriptor() throws {
        let fixture = try makeCompiledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workingDirectory = fixture.root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: false)
        try setMode(0o700, at: workingDirectory)

        let result = try SecureSubprocessRunner().run(
            SecureSubprocessRequest(
                executablePath: fixture.executable.path,
                arguments: ["cwd"],
                workingDirectory: workingDirectory.path
            )
        )

        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self),
            try canonicalPath(workingDirectory.path)
        )
    }

    func testTimeoutUsesBoundedTermination() {
        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: "/bin/sleep",
                    arguments: ["30"],
                    timeoutMilliseconds: 100,
                    terminationGraceMilliseconds: 50
                )
            )
        ) { error in
            guard case .timedOut(let result) = error as? SecureSubprocessError else {
                return XCTFail("Expected timedOut, received \(error)")
            }
            XCTAssertNotNil(result.terminationSignal)
            XCTAssertLessThan(result.durationMilliseconds, 2_000)
        }
    }

    func testTaskCancellationTerminatesTheProcess() async {
        let task = Task {
            try await SecureSubprocessRunner().runAsync(
                SecureSubprocessRequest(
                    executablePath: "/bin/sleep",
                    arguments: ["30"],
                    timeoutMilliseconds: 10_000,
                    terminationGraceMilliseconds: 50
                )
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch let error as SecureSubprocessError {
            guard case .cancelled(let result) = error else {
                return XCTFail("Expected cancelled, received \(error)")
            }
            XCTAssertNotNil(result.terminationSignal)
            XCTAssertLessThan(result.durationMilliseconds, 2_000)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutTerminatesLeaderAndIgnoringDescendant() throws {
        let fixture = try makeCompiledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.root.appendingPathComponent("timeout-pids")

        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: fixture.executable.path,
                    arguments: ["fork-sleep", pidFile.path],
                    timeoutMilliseconds: 150,
                    terminationGraceMilliseconds: 50
                )
            )
        ) { error in
            guard case .timedOut = error as? SecureSubprocessError else {
                return XCTFail("Expected timedOut, received \(error)")
            }
        }

        try assertRecordedProcessesAreGone(pidFile)
    }

    func testLeaderExitWithLiveDescendantFailsAndCleansProcessGroup() throws {
        let fixture = try makeCompiledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.root.appendingPathComponent("descendant-pids")

        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: fixture.executable.path,
                    arguments: ["fork-exit", pidFile.path],
                    timeoutMilliseconds: 5_000,
                    terminationGraceMilliseconds: 50
                )
            )
        ) { error in
            guard case .descendantProcessDetected = error as? SecureSubprocessError else {
                return XCTFail("Expected descendantProcessDetected, received \(error)")
            }
        }

        try assertRecordedProcessesAreGone(pidFile)
    }

    func testCancellationTerminatesLeaderAndIgnoringDescendant() async throws {
        let fixture = try makeCompiledFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.root.appendingPathComponent("cancel-pids")
        let task = Task {
            try await SecureSubprocessRunner().runAsync(
                SecureSubprocessRequest(
                    executablePath: fixture.executable.path,
                    arguments: ["fork-sleep", pidFile.path],
                    timeoutMilliseconds: 10_000,
                    terminationGraceMilliseconds: 50
                )
            )
        }
        try await waitForFile(pidFile)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch let error as SecureSubprocessError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, received \(error)")
            }
        }
        try assertRecordedProcessesAreGone(pidFile)
    }

    func testRepeatedCancellationRacesReturnOnlyCancelled() async {
        for iteration in 0..<20 {
            let task = Task {
                try await SecureSubprocessRunner().runAsync(
                    SecureSubprocessRequest(
                        executablePath: "/bin/sleep",
                        arguments: ["30"],
                        timeoutMilliseconds: 10_000,
                        terminationGraceMilliseconds: 20
                    )
                )
            }
            try? await Task.sleep(for: .milliseconds(iteration % 3 == 0 ? 1 : 10))
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation in iteration \(iteration).")
            } catch let error as SecureSubprocessError {
                guard case .cancelled = error else {
                    return XCTFail("Expected cancelled in iteration \(iteration), received \(error)")
                }
            } catch {
                return XCTFail("Unexpected error in iteration \(iteration): \(error)")
            }
        }
    }

    func testCancellationBeforeLaunchCreatesNoProcess() {
        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(executablePath: "/does/not/exist"),
                cancellation: cancellation
            )
        ) { error in
            guard case .cancelled(let result) = error as? SecureSubprocessError else {
                return XCTFail("Expected cancelled, received \(error)")
            }
            XCTAssertEqual(result.exitStatus, -1)
            XCTAssertEqual(result.durationMilliseconds, 0)
        }
    }

    func testSystemSymlinkResolvesToVerifiedCanonicalExecutable() throws {
        let executable = try SecureExecutableResolver.verify(path: "/usr/bin/tar")

        XCTAssertEqual(executable.path, "/usr/bin/bsdtar")
        XCTAssertEqual(executable.ownerUserID, 0)
    }

    func testResolverFailsClosedOnUnsafePathCandidate() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafeDirectory = root.appendingPathComponent("unsafe-bin", isDirectory: true)
        let safeDirectory = root.appendingPathComponent("safe-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: safeDirectory, withIntermediateDirectories: false)
        try setMode(0o700, at: unsafeDirectory)
        try setMode(0o700, at: safeDirectory)
        let unsafeExecutable = unsafeDirectory.appendingPathComponent("container")
        let safeExecutable = safeDirectory.appendingPathComponent("container")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/printf"), to: unsafeExecutable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/printf"), to: safeExecutable)
        try setMode(0o777, at: unsafeExecutable)
        try setMode(0o700, at: safeExecutable)

        XCTAssertThrowsError(
            try SecureExecutableResolver.resolve(
                named: "container",
                searchPath: "\(unsafeDirectory.path):\(safeDirectory.path)"
            )
        ) { error in
            XCTAssertEqual(error as? SecureExecutableValidationError, .unsafeOwnership)
        }

        let system = try SecureExecutableResolver.resolve(named: "printf", searchPath: "/usr/bin")
        XCTAssertEqual(system?.ownerUserID, 0)
    }

    func testExecutableIdentityDetectsMutationAndUnsafeParent() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("verified-executable")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/printf"), to: executable)
        try setMode(0o700, at: executable)
        let identity = try SecureExecutableResolver.verify(path: executable.path)

        let handle = try FileHandle(forWritingTo: executable)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertThrowsError(try SecureExecutableResolver.verifyUnchanged(identity)) { error in
            XCTAssertEqual(error as? SecureExecutableValidationError, .metadataChanged)
        }

        try setMode(0o777, at: root)
        XCTAssertThrowsError(try SecureExecutableResolver.verify(path: executable.path)) { error in
            XCTAssertEqual(error as? SecureExecutableValidationError, .unsafePermissions)
        }
    }

    func testWorkingDirectoryAndLexicalTraversalValidationFailClosed() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            try SecureExecutableResolver.verifyWorkingDirectory(path: root.path),
            try canonicalPath(root.path)
        )

        try setMode(0o777, at: root)
        XCTAssertThrowsError(try SecureExecutableResolver.verifyWorkingDirectory(path: root.path)) { error in
            XCTAssertEqual(error as? SecureExecutableValidationError, .unsafePermissions)
        }
        XCTAssertThrowsError(try SecureExecutableResolver.verify(path: "/usr/bin/../bin/printf")) { error in
            XCTAssertEqual(error as? SecureExecutableValidationError, .invalidPath)
        }
    }

    func testRequestRejectsLoaderEnvironmentAndOversizedInputBeforeLaunch() {
        var unsafeEnvironment = SecureSubprocessEnvironment.minimal
        unsafeEnvironment["DYLD_INSERT_LIBRARIES"] = "/tmp/attack.dylib"
        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(executablePath: "/usr/bin/printf", environment: unsafeEnvironment)
            )
        ) { error in
            XCTAssertEqual(error as? SecureSubprocessError, .invalidRequest(.unsafeEnvironment))
        }

        var nonASCIIEnvironment = SecureSubprocessEnvironment.minimal
        nonASCIIEnvironment["HÖSTWRIGHT"] = "invalid"
        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(executablePath: "/usr/bin/printf", environment: nonASCIIEnvironment)
            )
        ) { error in
            XCTAssertEqual(error as? SecureSubprocessError, .invalidRequest(.invalidEnvironment))
        }

        XCTAssertThrowsError(
            try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: "/usr/bin/printf",
                    standardInput: Data(repeating: 0, count: 2),
                    maximumStandardInputBytes: 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? SecureSubprocessError, .invalidRequest(.invalidInputLimit))
        }
    }

    private func makeCompiledFixture() throws -> (root: URL, executable: URL) {
        let root = try makePrivateTemporaryDirectory()
        let executable = root.appendingPathComponent("secure-subprocess-fixture")
        let source = try XCTUnwrap(
            Bundle.module.url(forResource: "SecureSubprocessFixture", withExtension: "swift")
        )
        do {
            let result = try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: "/usr/bin/swiftc",
                    arguments: [source.path, "-o", executable.path],
                    timeoutMilliseconds: 30_000,
                    maximumStandardOutputBytes: 1 * 1_024 * 1_024,
                    maximumStandardErrorBytes: 1 * 1_024 * 1_024
                )
            )
            guard result.exitStatus == 0 else {
                throw NSError(
                    domain: "SecureSubprocessTests",
                    code: Int(result.exitStatus),
                    userInfo: [NSLocalizedDescriptionKey: String(decoding: result.standardError, as: UTF8.self)]
                )
            }
            try setMode(0o700, at: executable)
            return (root, executable)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func assertRecordedProcessesAreGone(_ pidFile: URL) throws {
        let components = try String(contentsOf: pidFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
        let processIDs = try components.map { component -> pid_t in
            guard let value = pid_t(component) else {
                throw NSError(domain: "SecureSubprocessTests", code: 1)
            }
            return value
        }
        XCTAssertEqual(processIDs.count, 2)
        for processID in processIDs {
            XCTAssertFalse(processExists(processID), "Process \(processID) survived process-group cleanup.")
        }
    }

    private func processExists(_ processID: pid_t) -> Bool {
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "SecureSubprocessTests", code: 2)
    }

    private func setMode(_ mode: mode_t, at url: URL) throws {
        guard chmod(url.path, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func canonicalPath(_ path: String) throws -> String {
        guard let pointer = realpath(path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private func makePrivateTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-secure-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }
}

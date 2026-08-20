import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import HostwrightCore

final class DarwinProcessIdentityTests: XCTestCase {
    func testSyntheticProcArgumentsPreserveExactArgcSpacesAndNewlines() throws {
        let data = procArguments(
            executable: "/usr/bin/printf",
            arguments: ["/usr/bin/printf", "space value", "line\nvalue"]
        )
        let parsed = try HostwrightDarwinProcessIdentity.parseArguments(data)
        XCTAssertEqual(parsed.executablePath, "/usr/bin/printf")
        XCTAssertEqual(parsed.arguments, ["/usr/bin/printf", "space value", "line\nvalue"])
    }

    func testSyntheticProcArgumentsRejectTruncationMalformedUTF8AndWrongArgc() throws {
        var truncated = procArguments(
            executable: "/usr/bin/printf",
            arguments: ["/usr/bin/printf", "value"]
        )
        truncated.removeLast()
        XCTAssertThrowsError(try HostwrightDarwinProcessIdentity.parseArguments(truncated))

        var malformed = procArguments(
            executable: "/usr/bin/printf",
            arguments: ["/usr/bin/printf"]
        )
        malformed[malformed.count - 2] = 0xff
        XCTAssertThrowsError(try HostwrightDarwinProcessIdentity.parseArguments(malformed))

        var wrongCount: Int32 = 2
        var wrongCountData = Data()
        withUnsafeBytes(of: &wrongCount) { wrongCountData.append(contentsOf: $0) }
        wrongCountData.append(Data("/usr/bin/printf\0\0/usr/bin/printf\0".utf8))
        XCTAssertThrowsError(try HostwrightDarwinProcessIdentity.parseArguments(wrongCountData))
    }

    func testLengthPrefixedArgumentIdentityRejectsConcatenationCollisions() throws {
        let first = try HostwrightDarwinProcessIdentity.canonicalArguments(["/bin/echo", "ab", "c"])
        let second = try HostwrightDarwinProcessIdentity.canonicalArguments(["/bin/echo", "a", "bc"])
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(SHA256.hash(data: first), SHA256.hash(data: second))
    }

    func testLiveIdentityBindsKernelPathArgumentsAndStartTime() throws {
        let path = "/bin/sleep"
        let executable = try SecureExecutableResolver.verify(
            path: path,
            ownershipPolicy: .rootOnly
        )
        var attributes: posix_spawnattr_t? = nil
        let attributeResult = posix_spawnattr_init(&attributes)
        XCTAssertEqual(attributeResult, 0)
        guard attributeResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: attributeResult) ?? .EINVAL)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flagResult = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_START_SUSPENDED)
        )
        XCTAssertEqual(flagResult, 0)
        guard flagResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: flagResult) ?? .EINVAL)
        }
        var arguments = try cStringVector([path, "30"])
        defer { freeCStringVector(&arguments) }
        var environment = try cStringVector(["PATH=/usr/bin:/bin"])
        defer { freeCStringVector(&environment) }
        var processID = pid_t(0)
        let spawnResult = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    path,
                    nil,
                    &attributes,
                    argumentBuffer.baseAddress!,
                    environmentBuffer.baseAddress!
                )
            }
        }
        XCTAssertEqual(spawnResult, 0)
        guard spawnResult == 0, processID > 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EINVAL)
        }
        defer { terminateAndReap(processID) }

        let live = try HostwrightDarwinProcessIdentity.lookup(processID: processID)
        let rebound = try HostwrightDarwinProcessIdentity.lookup(
            processID: processID, expectedExecutable: executable)
        XCTAssertEqual(rebound, live)
        XCTAssertEqual(live.processID, processID)
        XCTAssertEqual(live.executablePath, path)
        let expectedCommand = try HostwrightDarwinProcessIdentity.canonicalArguments([path, "30"])
        XCTAssertEqual(live.commandSHA256, SHA256.hash(data: expectedCommand).hexadecimal)
        XCTAssertEqual(live.startSHA256.count, 64)
        XCTAssertEqual(live.commandSHA256.count, 64)
        XCTAssertTrue(live.strongIdentity.hasPrefix("v1."))
        XCTAssertTrue(live.ownershipToken.hasPrefix("pid=\(processID);command_sha256="))

        let wrong = try SecureExecutableResolver.verify(path: "/usr/bin/false", ownershipPolicy: .rootOnly)
        XCTAssertThrowsError(
            try HostwrightDarwinProcessIdentity.lookup(
                processID: processID,
                expectedExecutable: wrong
            )
        ) { error in
            XCTAssertEqual(error as? HostwrightDarwinProcessIdentityError, .executableMismatch)
        }
    }

    private func procArguments(executable: String, arguments: [String]) -> Data {
        var count = Int32(arguments.count)
        var data = Data()
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(Data(executable.utf8))
        data.append(0)
        data.append(0)
        for argument in arguments {
            data.append(Data(argument.utf8))
            data.append(0)
        }
        return data
    }

    private func cStringVector(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                freeCStringVector(&result)
                throw POSIXError(.ENOMEM)
            }
            result.append(pointer)
        }
        result.append(nil)
        return result
    }

    private func freeCStringVector(_ vector: inout [UnsafeMutablePointer<CChar>?]) {
        for pointer in vector { free(pointer) }
        vector.removeAll(keepingCapacity: false)
    }

    private func terminateAndReap(_ processID: pid_t) {
        if kill(processID, SIGKILL) != 0, errno != ESRCH { return }
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, 0)
            if result == processID { return }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == ECHILD { return }
            return
        }
    }
}

private extension SHA256.Digest {
    var hexadecimal: String { map { String(format: "%02x", $0) }.joined() }
}

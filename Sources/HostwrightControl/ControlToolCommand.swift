import Darwin
import Foundation
import HostwrightCore

public enum LocalControlToolCommand: Equatable, Sendable {
    case version
    case help
    case run(LocalControlConfiguration)

    public static func parse(arguments: [String]) throws -> LocalControlToolCommand {
        guard !arguments.isEmpty else { return .help }
        if arguments == ["--version"] || arguments == ["version"] { return .version }
        if arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] { return .help }

        var manifestPath: String?
        var stateDatabasePath: String?
        var teamProfilePath: String?
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--manifest", "--state-db", "--team-profile"].contains(flag) else {
                throw LocalControlUsageError("hostwright-control does not support argument '\(flag)'.")
            }
            guard index + 1 < arguments.count else {
                throw LocalControlUsageError("hostwright-control requires a value after \(flag).")
            }
            let value = arguments[index + 1]
            guard value.hasPrefix("/"), !value.hasPrefix("-") else {
                throw LocalControlUsageError("hostwright-control requires an absolute path after \(flag).")
            }

            switch flag {
            case "--manifest":
                guard manifestPath == nil else { throw LocalControlUsageError("--manifest may be supplied only once.") }
                manifestPath = value
            case "--state-db":
                guard stateDatabasePath == nil else { throw LocalControlUsageError("--state-db may be supplied only once.") }
                stateDatabasePath = value
            case "--team-profile":
                guard teamProfilePath == nil else { throw LocalControlUsageError("--team-profile may be supplied only once.") }
                teamProfilePath = value
            default:
                break
            }
            index += 2
        }

        guard let manifestPath else {
            throw LocalControlUsageError("hostwright-control requires --manifest <absolute-path>.")
        }
        return .run(
            LocalControlConfiguration(
                manifestPath: manifestPath,
                stateDatabasePath: stateDatabasePath,
                teamProfilePath: teamProfilePath
            )
        )
    }

    public static let helpText = """
    Hostwright local control API

    Usage:
      hostwright-control --version
      hostwright-control --manifest <absolute-path> [--state-db <absolute-path>] [--team-profile <absolute-path>]

    Reads exactly one version-1 JSON request from stdin, writes exactly one JSON response to stdout, and exits.
    Supported operations: plan, status, events, recovery, doctor.
    Manifest, state, and team-profile paths are fixed by launch arguments and cannot be supplied by a request.
    This process does not expose apply, cleanup, logs, diagnostics export, benchmark, extension execution, or any generic mutation operation.

    """
}

public struct LocalControlUsageError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public enum LocalControlInputReader {
    public static func read(
        descriptor: Int32 = STDIN_FILENO,
        timeoutMilliseconds: Int = 5_000,
        maximumBytes: Int = LocalControlRequestParser.maximumRequestBytes
    ) throws -> Data {
        guard timeoutMilliseconds > 0, maximumBytes > 0 else {
            throw invalid("The local control input limits are invalid.")
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw invalid("Timed out waiting for one local control request on stdin.")
            }
            let remainingMilliseconds = max(1, Int((deadline - now) / 1_000_000))
            var descriptorState = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = poll(&descriptorState, 1, Int32(clamping: remainingMilliseconds))
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0 else {
                throw invalid("Timed out waiting for one local control request on stdin.")
            }
            guard descriptorState.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                throw invalid("Could not read the local control request from stdin.")
            }

            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw invalid("Could not read the local control request from stdin.")
            }
            if count == 0 { return data }
            guard data.count + count <= maximumBytes else {
                throw invalid("The local control request exceeded the 64 KiB input limit.")
            }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    private static func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .controlAPIInvalid, message: message)
    }
}

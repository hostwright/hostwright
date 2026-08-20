import CryptoKit
import Darwin
import Foundation

public enum HostwrightDarwinProcessIdentityError: Error, Equatable, Sendable {
    case invalidProcessID
    case processUnavailable
    case invalidExecutablePath
    case executableMismatch
    case invalidArguments
    case argumentsTooLarge
}

public struct HostwrightDarwinProcessIdentity: Codable, Equatable, Sendable {
    public let processID: Int32
    public let executablePath: String
    public let commandSHA256: String
    public let startSHA256: String
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(
        processID: Int32,
        executablePath: String,
        commandSHA256: String,
        startSHA256: String,
        startSeconds: UInt64,
        startMicroseconds: UInt64
    ) {
        self.processID = processID
        self.executablePath = executablePath
        self.commandSHA256 = commandSHA256
        self.startSHA256 = startSHA256
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    public var ownershipToken: String {
        "pid=\(processID);command_sha256=\(commandSHA256);start_sha256=\(startSHA256)"
    }

    public var strongIdentity: String {
        let pathDigest = Self.sha256(Data(executablePath.utf8))
        return "v1.\(pathDigest).\(commandSHA256).\(startSeconds).\(startMicroseconds)"
    }

    public static func lookup(
        processID: Int32,
        expectedExecutable: SecureExecutableIdentity? = nil
    ) throws -> Self {
        guard processID > 0 else { throw HostwrightDarwinProcessIdentityError.invalidProcessID }

        let information = try processInformation(processID: processID)
        let canonicalKernelPath = try executablePath(processID: processID)

        if let expectedExecutable {
            do { try SecureExecutableResolver.verifyUnchanged(expectedExecutable) }
            catch { throw HostwrightDarwinProcessIdentityError.executableMismatch }
            guard canonicalKernelPath == expectedExecutable.path else {
                throw HostwrightDarwinProcessIdentityError.executableMismatch
            }
        }

        let parsed = try parseArguments(processArguments(processID: processID))
        guard let canonicalProcArgsPath = canonicalPath(parsed.executablePath),
              let canonicalArgvZero = parsed.arguments.first.flatMap(canonicalPath),
              canonicalProcArgsPath == canonicalKernelPath,
              canonicalArgvZero == canonicalKernelPath else {
            throw HostwrightDarwinProcessIdentityError.executableMismatch
        }

        let repeated = try parseArguments(processArguments(processID: processID))
        let repeatedInformation = try processInformation(processID: processID)
        let repeatedPath = try executablePath(processID: processID)
        guard repeated.executablePath == parsed.executablePath,
              repeated.arguments == parsed.arguments,
              repeatedPath == canonicalKernelPath,
              repeatedInformation.pbi_start_tvsec == information.pbi_start_tvsec,
              repeatedInformation.pbi_start_tvusec == information.pbi_start_tvusec else {
            throw HostwrightDarwinProcessIdentityError.processUnavailable
        }
        if let expectedExecutable {
            do { try SecureExecutableResolver.verifyUnchanged(expectedExecutable) }
            catch { throw HostwrightDarwinProcessIdentityError.executableMismatch }
        }

        let commandDigest = sha256(try canonicalArguments(parsed.arguments))
        let seconds = UInt64(information.pbi_start_tvsec)
        let microseconds = UInt64(information.pbi_start_tvusec)
        guard microseconds < 1_000_000 else {
            throw HostwrightDarwinProcessIdentityError.processUnavailable
        }
        let startDigest = sha256(canonicalStart(seconds: seconds, microseconds: microseconds))
        return Self(
            processID: processID,
            executablePath: canonicalKernelPath,
            commandSHA256: commandDigest,
            startSHA256: startDigest,
            startSeconds: seconds,
            startMicroseconds: microseconds
        )
    }

    public static func parseArguments(_ data: Data) throws
        -> (executablePath: String, arguments: [String])
    {
        guard data.count > MemoryLayout<Int32>.size, data.count <= 1_048_576 else {
            throw HostwrightDarwinProcessIdentityError.invalidArguments
        }
        let argumentCount: Int32 = data.prefix(MemoryLayout<Int32>.size).withUnsafeBytes { source in
            var value: Int32 = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: source)
            }
            return value
        }
        guard argumentCount > 0, argumentCount <= 4_096 else {
            throw HostwrightDarwinProcessIdentityError.invalidArguments
        }
        let bytes = [UInt8](data.dropFirst(MemoryLayout<Int32>.size))
        guard let executableEnd = bytes.firstIndex(of: 0), executableEnd > 0,
              let executablePath = String(bytes: bytes[..<executableEnd], encoding: .utf8),
              executablePath.utf8.count < Int(PATH_MAX) else {
            throw HostwrightDarwinProcessIdentityError.invalidArguments
        }
        var offset = executableEnd
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        for _ in 0..<Int(argumentCount) {
            guard offset < bytes.count,
                  let relativeEnd = bytes[offset...].firstIndex(of: 0),
                  relativeEnd >= offset,
                  let argument = String(bytes: bytes[offset..<relativeEnd], encoding: .utf8) else {
                throw HostwrightDarwinProcessIdentityError.invalidArguments
            }
            arguments.append(argument)
            offset = relativeEnd + 1
        }
        guard arguments.count == Int(argumentCount), !arguments[0].isEmpty else {
            throw HostwrightDarwinProcessIdentityError.invalidArguments
        }
        return (executablePath, arguments)
    }

    public static func canonicalArguments(_ arguments: [String]) throws -> Data {
        guard !arguments.isEmpty, arguments.count <= 4_096 else {
            throw HostwrightDarwinProcessIdentityError.invalidArguments
        }
        var data = Data("hostwright.process.argv.v1\0".utf8)
        append(UInt64(arguments.count), to: &data)
        for argument in arguments {
            let bytes = Data(argument.utf8)
            guard bytes.count <= 1_048_576, !bytes.contains(0) else {
                throw HostwrightDarwinProcessIdentityError.argumentsTooLarge
            }
            append(UInt64(bytes.count), to: &data)
            data.append(bytes)
        }
        guard data.count <= 1_048_576 else {
            throw HostwrightDarwinProcessIdentityError.argumentsTooLarge
        }
        return data
    }

    public static func canonicalStart(seconds: UInt64, microseconds: UInt64) -> Data {
        var data = Data("hostwright.process.start.v1\0".utf8)
        append(seconds, to: &data)
        append(microseconds, to: &data)
        return data
    }

    private static func processInformation(processID: Int32) throws -> proc_bsdinfo {
        var information = proc_bsdinfo()
        let informationSize = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &information,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard informationSize == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            throw HostwrightDarwinProcessIdentityError.processUnavailable
        }
        return information
    }

    private static func executablePath(processID: Int32) throws -> String {
        let maximumPathBytes = 4 * Int(MAXPATHLEN)
        var pathBytes = [CChar](repeating: 0, count: maximumPathBytes)
        let pathLength = proc_pidpath(processID, &pathBytes, UInt32(pathBytes.count))
        guard pathLength > 0, Int(pathLength) <= pathBytes.count,
              let pathEnd = pathBytes.firstIndex(of: 0), pathEnd > 0 else {
            throw HostwrightDarwinProcessIdentityError.processUnavailable
        }
        let kernelPathBytes = pathBytes[..<pathEnd].map { UInt8(bitPattern: $0) }
        guard let kernelPath = String(bytes: kernelPathBytes, encoding: .utf8),
              let canonicalKernelPath = canonicalPath(kernelPath) else {
            throw HostwrightDarwinProcessIdentityError.invalidExecutablePath
        }
        return canonicalKernelPath
    }

    private static func processArguments(processID: Int32) throws -> Data {
        var mib = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size,
              size <= 1_048_576 else {
            throw HostwrightDarwinProcessIdentityError.processUnavailable
        }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { storage in
            sysctl(&mib, u_int(mib.count), storage.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size, size <= data.count else {
            throw HostwrightDarwinProcessIdentityError.processUnavailable
        }
        return Data(data.prefix(size))
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < Int(PATH_MAX),
              let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        guard canonical.hasPrefix("/"), canonical.utf8.count < Int(PATH_MAX),
              !canonical.contains("\0") else { return nil }
        return canonical
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

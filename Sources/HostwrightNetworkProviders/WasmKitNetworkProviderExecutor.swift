import Foundation
import HostwrightCore
import WasmKit

public struct WasmKitNetworkProviderExecutor: NetworkProviderWasmExecutor {
    public static let workerExecutableName = "hostwright-network-provider-worker"
    public static let maximumModuleBytes = 16 * 1_024 * 1_024
    public static let maximumInputBytes = 1 * 1_024 * 1_024
    public static let maximumWorkerRequestBytes = 24 * 1_024 * 1_024
    public static let maximumWorkerResponseBytes = 2 * 1_024 * 1_024

    private let workerExecutableURL: URL

    public init(workerExecutableURL: URL? = nil) throws {
        if let workerExecutableURL {
            self.workerExecutableURL = workerExecutableURL
            return
        }

        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
        let candidate = executableDirectory.appendingPathComponent(Self.workerExecutableName)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw NetworkProviderError.executionFailed
        }
        self.workerExecutableURL = candidate
    }

    public func execute(
        module: Data,
        stdin: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data {
        guard module.count <= Self.maximumModuleBytes,
              stdin.count <= Self.maximumInputBytes,
              sandbox.memoryLimitBytes <= NetworkProviderSandbox.maximumMemoryBytes,
              sandbox.outputLimitBytes <= NetworkProviderSandbox.maximumOutputBytes
        else {
            throw NetworkProviderError.executionFailed
        }

        return try await Self.runWorker(
            executableURL: workerExecutableURL,
            module: module,
            input: stdin,
            sandbox: sandbox
        )
    }

    private static func runWorker(
        executableURL: URL,
        module: Data,
        input: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data {
        let request = WasmWorkerRequest(
            module: module,
            input: input,
            memoryLimitBytes: sandbox.memoryLimitBytes,
            outputLimitBytes: sandbox.outputLimitBytes
        )
        let encodedRequest = try JSONEncoder().encode(request)
        guard encodedRequest.count <= Self.maximumWorkerRequestBytes else {
            throw NetworkProviderError.executionFailed
        }

        let subprocessRequest = SecureSubprocessRequest(
            executablePath: executableURL.path,
            environment: SecureSubprocessEnvironment.minimal,
            workingDirectory: "/",
            standardInput: encodedRequest,
            timeoutMilliseconds: sandbox.timeoutMilliseconds,
            terminationGraceMilliseconds: 100,
            maximumStandardOutputBytes: Self.maximumWorkerResponseBytes,
            maximumStandardErrorBytes: 64 * 1_024,
            maximumStandardInputBytes: Self.maximumWorkerRequestBytes
        )
        let result: SecureSubprocessResult
        do {
            result = try await SecureSubprocessRunner().runAsync(
                subprocessRequest
            )
        } catch let error as SecureSubprocessError {
            if case .outputLimitExceeded = error {
                throw NetworkProviderError.outputLimitExceeded
            }
            throw NetworkProviderError.executionFailed
        } catch {
            throw NetworkProviderError.executionFailed
        }
        guard result.exitStatus == 0,
              result.terminationSignal == nil,
              !result.standardOutputTruncated,
              !result.standardErrorTruncated,
              let response = try? JSONDecoder().decode(
                  WasmWorkerResponse.self,
                  from: result.standardOutput
              )
        else {
            throw NetworkProviderError.executionFailed
        }
        if let error = response.error {
            throw error == .outputLimitExceeded
                ? NetworkProviderError.outputLimitExceeded
                : NetworkProviderError.executionFailed
        }
        guard let output = response.output,
              output.count <= sandbox.outputLimitBytes
        else {
            throw NetworkProviderError.outputLimitExceeded
        }
        return output
    }
}

public enum WasmKitNetworkProviderRuntime {
    public static func execute(
        moduleBytes: Data,
        input: Data,
        memoryLimitBytes: Int,
        outputLimitBytes: Int
    ) throws -> Data {
        guard memoryLimitBytes > 0,
              memoryLimitBytes <= NetworkProviderSandbox.maximumMemoryBytes,
              outputLimitBytes > 0,
              outputLimitBytes <= NetworkProviderSandbox.maximumOutputBytes,
              moduleBytes.count
                  <= WasmKitNetworkProviderExecutor.maximumModuleBytes,
              input.count <= WasmKitNetworkProviderExecutor.maximumInputBytes
        else {
            throw NetworkProviderError.executionFailed
        }

        try validateMemoryDeclaration(
            moduleBytes,
            maximumPages: UInt64(memoryLimitBytes / 65_536)
        )
        let configuration = EngineConfiguration(
            threadingModel: .direct,
            compilationMode: .lazy,
            stackSize: 512 * 1_024,
            memoryBoundsChecking: .software
        )
        let engine = Engine(configuration: configuration)
        let store = Store(engine: engine)
        let module = try parseWasm(bytes: Array(moduleBytes))
        guard module.imports.isEmpty else {
            throw NetworkProviderError.executionFailed
        }
        let instance = try module.instantiate(store: store, imports: Imports())
        guard let memory = instance.exports[memory: "memory"],
              memory.type.max.map({ $0 <= UInt64(memoryLimitBytes / 65_536) }) == true,
              memory.byteCount <= memoryLimitBytes,
              let allocate = instance.exports[function: "hostwright_alloc"],
              allocate.type.parameters == [.i32],
              allocate.type.results == [.i32],
              let run = instance.exports[function: "hostwright_run"],
              run.type.parameters == [.i32, .i32],
              run.type.results == [.i64]
        else {
            throw NetworkProviderError.executionFailed
        }

        let allocation = try allocate([.i32(UInt32(input.count))])
        guard case .i32(let inputPointer) = allocation.first,
              allocation.count == 1,
              checkedRange(
                  offset: UInt64(inputPointer),
                  count: UInt64(input.count),
                  limit: UInt64(memory.byteCount)
              ) != nil
        else {
            throw NetworkProviderError.executionFailed
        }
        _ = memory.withUnsafeMutableBufferPointer(
            offset: UInt(inputPointer),
            count: input.count
        ) { destination in
            input.copyBytes(to: destination)
        }

        let result = try run([.i32(inputPointer), .i32(UInt32(input.count))])
        guard case .i64(let packed) = result.first,
              result.count == 1
        else {
            throw NetworkProviderError.executionFailed
        }
        let outputPointer = UInt64(UInt32(truncatingIfNeeded: packed >> 32))
        let outputCount = UInt64(UInt32(truncatingIfNeeded: packed))
        guard outputCount <= UInt64(outputLimitBytes),
              let outputRange = checkedRange(
                  offset: outputPointer,
                  count: outputCount,
                  limit: UInt64(memory.byteCount)
              )
        else {
            throw NetworkProviderError.outputLimitExceeded
        }
        return memory.withUnsafeBufferPointer(
            offset: UInt(outputRange.lowerBound),
            count: Int(outputCount)
        ) { Data($0) }
    }

    private static func checkedRange(
        offset: UInt64,
        count: UInt64,
        limit: UInt64
    ) -> Range<UInt64>? {
        let (end, overflow) = offset.addingReportingOverflow(count)
        guard !overflow, end <= limit else {
            return nil
        }
        return offset..<end
    }

    private static func validateMemoryDeclaration(
        _ module: Data,
        maximumPages: UInt64
    ) throws {
        var reader = WasmBinaryReader(bytes: Array(module))
        guard try reader.read(count: 8) == [0, 97, 115, 109, 1, 0, 0, 0] else {
            throw NetworkProviderError.executionFailed
        }
        var foundMemory = false
        while !reader.isAtEnd {
            let section = try reader.readByte()
            let size = try reader.readULEB()
            let payload = try reader.read(count: Int(size))
            guard section != 2 else {
                throw NetworkProviderError.executionFailed
            }
            guard section == 5 else {
                continue
            }
            var memoryReader = WasmBinaryReader(bytes: payload)
            guard try memoryReader.readULEB() == 1 else {
                throw NetworkProviderError.executionFailed
            }
            let flags = try memoryReader.readULEB()
            guard flags == 1 else {
                throw NetworkProviderError.executionFailed
            }
            let minimum = try memoryReader.readULEB()
            let maximum = try memoryReader.readULEB()
            guard memoryReader.isAtEnd,
                  minimum <= maximum,
                  maximum <= maximumPages
            else {
                throw NetworkProviderError.executionFailed
            }
            foundMemory = true
        }
        guard foundMemory else {
            throw NetworkProviderError.executionFailed
        }
    }
}

public struct WasmWorkerRequest: Codable, Sendable {
    public let module: Data
    public let input: Data
    public let memoryLimitBytes: Int
    public let outputLimitBytes: Int

    public init(
        module: Data,
        input: Data,
        memoryLimitBytes: Int,
        outputLimitBytes: Int
    ) {
        self.module = module
        self.input = input
        self.memoryLimitBytes = memoryLimitBytes
        self.outputLimitBytes = outputLimitBytes
    }
}

public struct WasmWorkerResponse: Codable, Sendable {
    public let output: Data?
    public let error: NetworkProviderError?

    public init(output: Data?, error: NetworkProviderError?) {
        self.output = output
        self.error = error
    }
}

private struct WasmBinaryReader {
    let bytes: [UInt8]
    var offset = 0

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw NetworkProviderError.executionFailed
        }
        defer {
            offset += 1
        }
        return bytes[offset]
    }

    mutating func read(count: Int) throws -> [UInt8] {
        guard count >= 0,
              offset <= bytes.count,
              count <= bytes.count - offset
        else {
            throw NetworkProviderError.executionFailed
        }
        defer {
            offset += count
        }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func readULEB() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            let byte = try readByte()
            let payload = UInt64(byte & 0x7f)
            guard shift < 64,
                  payload <= UInt64.max >> shift
            else {
                throw NetworkProviderError.executionFailed
            }
            result |= payload << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        throw NetworkProviderError.executionFailed
    }
}

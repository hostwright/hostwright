import Darwin
import Foundation
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

        let controller = WorkerProcessController()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try Self.runWorker(
                    executableURL: workerExecutableURL,
                    module: module,
                    input: stdin,
                    sandbox: sandbox,
                    controller: controller
                )
            }.value
        } onCancel: {
            controller.cancel()
        }
    }

    private static func runWorker(
        executableURL: URL,
        module: Data,
        input: Data,
        sandbox: NetworkProviderSandbox,
        controller: WorkerProcessController
    ) throws -> Data {
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

        let process = Process()
        process.executableURL = executableURL
        process.arguments = []
        process.environment = [:]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        controller.attach(process)
        guard !controller.isCancelled else {
            throw NetworkProviderError.executionFailed
        }
        let deadline = ContinuousClock.now
            .advanced(by: .milliseconds(sandbox.timeoutMilliseconds))
        try process.run()
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()

        let collector = BoundedPipeCollector(
            maximumBytes: Self.maximumWorkerResponseBytes,
            controller: controller
        )
        collector.start(reading: outputPipe.fileHandleForReading)
        let writer = BoundedPipeWriter()
        writer.start(
            writing: encodedRequest,
            to: inputPipe.fileHandleForWriting
        )

        while process.isRunning && ContinuousClock.now < deadline && !controller.isCancelled {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        let writeResult = writer.result()
        let collected = collector.result()
        controller.detach()

        if case .failure = writeResult {
            throw NetworkProviderError.executionFailed
        }
        switch collected {
        case .failure(let error):
            throw error
        case .success:
            break
        }
        guard !controller.isCancelled,
              ContinuousClock.now < deadline,
              process.terminationReason == .exit,
              process.terminationStatus == 0,
              case .success(let responseData) = collected,
              let response = try? JSONDecoder().decode(WasmWorkerResponse.self, from: responseData)
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

private final class WorkerProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock {
            cancelled
        }
    }

    func attach(_ process: Process) {
        lock.withLock {
            self.process = process
            if cancelled, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func detach() {
        lock.withLock {
            process = nil
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func terminate() {
        lock.withLock {
            if let process, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

private final class BoundedPipeCollector: @unchecked Sendable {
    private let maximumBytes: Int
    private let controller: WorkerProcessController
    private let condition = NSCondition()
    private var collected = Data()
    private var failure: NetworkProviderError?
    private var complete = false

    init(maximumBytes: Int, controller: WorkerProcessController) {
        self.maximumBytes = maximumBytes
        self.controller = controller
    }

    func start(reading handle: FileHandle) {
        Thread.detachNewThread {
            self.consume(handle)
        }
    }

    func result() -> Result<Data, NetworkProviderError> {
        condition.lock()
        while !complete {
            condition.wait()
        }
        let result: Result<Data, NetworkProviderError>
        if let failure {
            result = .failure(failure)
        } else {
            result = .success(collected)
        }
        condition.unlock()
        return result
    }

    private func consume(_ handle: FileHandle) {
        defer {
            try? handle.close()
        }
        do {
            while let chunk = try handle.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty
            {
                condition.lock()
                guard chunk.count <= maximumBytes - collected.count else {
                    failure = .outputLimitExceeded
                    condition.unlock()
                    controller.terminate()
                    finish()
                    return
                }
                collected.append(chunk)
                condition.unlock()
            }
        } catch {
            condition.lock()
            failure = .executionFailed
            condition.unlock()
        }
        finish()
    }

    private func finish() {
        condition.lock()
        complete = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class BoundedPipeWriter: @unchecked Sendable {
    private let condition = NSCondition()
    private var failure: NetworkProviderError?
    private var complete = false

    func start(writing data: Data, to handle: FileHandle) {
        Thread.detachNewThread {
            defer {
                try? handle.close()
                self.finish()
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                self.condition.lock()
                self.failure = .executionFailed
                self.condition.unlock()
            }
        }
    }

    func result() -> Result<Void, NetworkProviderError> {
        condition.lock()
        while !complete {
            condition.wait()
        }
        let result: Result<Void, NetworkProviderError>
        if let failure {
            result = .failure(failure)
        } else {
            result = .success(())
        }
        condition.unlock()
        return result
    }

    private func finish() {
        condition.lock()
        complete = true
        condition.broadcast()
        condition.unlock()
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

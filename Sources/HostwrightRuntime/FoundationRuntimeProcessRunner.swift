import Darwin
import Foundation

public struct FoundationRuntimeProcessRunner: RuntimeProcessRunning {
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(redactionPolicy: RuntimeRedactionPolicy = .default) {
        self.redactionPolicy = redactionPolicy
    }

    public func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try runSynchronously(spec))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runSynchronously(_ spec: RuntimeCommandSpec) throws -> RuntimeCommandResult {
        switch spec.classification {
        case .readOnly:
            try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        case .mutating:
            try RuntimeCommandPolicy.validateSupportedMutation(spec)
        case .forbidden, .unknown:
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Runtime process runner rejects forbidden and unknown command specs."
            )
        }

        guard FileManager.default.isExecutableFile(atPath: spec.executablePath) else {
            throw RuntimeAdapterError.executableNotFound(spec.executablePath).redacted(using: redactionPolicy)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executablePath)
        process.arguments = spec.arguments
        if let workingDirectory = spec.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if !spec.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            throw RuntimeAdapterError.commandFailed(
                exitStatus: -1,
                message: redactionPolicy.redact(String(describing: error)),
                standardError: ""
            )
        }

        let outputData = PipeReadBuffer()
        let errorData = PipeReadBuffer()
        let pipeReaders = DispatchGroup()
        pipeReaders.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            pipeReaders.leave()
        }
        pipeReaders.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            pipeReaders.leave()
        }

        let timeoutResult = semaphore.wait(timeout: .now() + .seconds(spec.timeout.seconds))
        if timeoutResult == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + .seconds(2)) == .timedOut {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                _ = semaphore.wait(timeout: .now() + .seconds(2))
            }
            if pipeReaders.wait(timeout: .now() + .seconds(2)) == .timedOut {
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                _ = pipeReaders.wait(timeout: .now() + .seconds(2))
            }

            let partialOutput = String(data: outputData.value(), encoding: .utf8) ?? ""
            let partialError = String(data: errorData.value(), encoding: .utf8) ?? ""

            throw RuntimeAdapterError.commandTimedOut(
                command: spec.redacted(using: redactionPolicy).purpose,
                partialOutput: redactionPolicy.redact(partialOutput, exactValues: spec.sensitiveValues),
                partialError: redactionPolicy.redact(partialError, exactValues: spec.sensitiveValues)
            )
        }

        if pipeReaders.wait(timeout: .now() + .seconds(2)) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = pipeReaders.wait(timeout: .now() + .seconds(2))
            throw RuntimeAdapterError.outputParseFailed(
                "Runtime command exited but its output pipes did not close within the bounded drain window."
            )
        }

        let standardOutput = String(data: outputData.value(), encoding: .utf8) ?? ""
        let standardError = String(data: errorData.value(), encoding: .utf8) ?? ""
        let result = RuntimeCommandResult(
            spec: spec,
            exitStatus: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        ).redacted(using: redactionPolicy)

        guard result.exitStatus == 0 else {
            throw RuntimeAdapterError.commandFailed(
                exitStatus: result.exitStatus,
                message: "\(spec.classification.rawValue) runtime command failed.",
                standardError: result.standardError
            )
        }

        return result
    }
}

private final class PipeReadBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    func set(_ data: Data) {
        lock.lock()
        stored = data
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

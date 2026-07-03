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
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(spec)
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

        do {
            try process.run()
        } catch {
            throw RuntimeAdapterError.commandFailed(
                exitStatus: -1,
                message: redactionPolicy.redact(String(describing: error)),
                standardError: ""
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        let timeoutResult = semaphore.wait(timeout: .now() + .seconds(spec.timeout.seconds))
        if timeoutResult == .timedOut {
            process.terminate()
            process.waitUntilExit()

            let partialOutput = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let partialError = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            throw RuntimeAdapterError.commandTimedOut(
                command: spec.redacted(using: redactionPolicy).purpose,
                partialOutput: redactionPolicy.redact(partialOutput),
                partialError: redactionPolicy.redact(partialError)
            )
        }

        let standardOutput = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let standardError = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

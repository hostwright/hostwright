import Foundation
import HostwrightAccelerator
import HostwrightCore

package struct AcceleratorXPCWorkerExecuteRequest: Codable, Equatable, Sendable {
    package let protocolVersion: Int
    package let payload: AcceleratorXPCExecutePayload
    package let modelArtifact: AcceleratorXPCModelArtifact

    package init(context: AcceleratorXPCBackendExecutionContext) throws {
        self.protocolVersion = AcceleratorXPCContract.currentVersion
        self.payload = context.payload
        self.modelArtifact = context.modelArtifact
        _ = try AcceleratorXPCWireJSON.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case payload
        case modelArtifact
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try AcceleratorXPCValidation.exactKeys(
            Set(container.allKeys.map(\.stringValue)),
            expected: ["protocolVersion", "payload", "modelArtifact"],
            field: "worker.request"
        )
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        try AcceleratorXPCValidation.version(protocolVersion)
        let payload = try container.decode(
            AcceleratorXPCExecutePayload.self,
            forKey: .payload
        )
        let modelArtifact = try container.decode(
            AcceleratorXPCModelArtifact.self,
            forKey: .modelArtifact
        )
        guard modelArtifact.modelHash == payload.request.modelHash else {
            throw AcceleratorXPCValidationError(code: .requestMismatch, field: "worker.modelHash")
        }
        self.protocolVersion = protocolVersion
        self.payload = payload
        self.modelArtifact = modelArtifact
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(payload, forKey: .payload)
        try container.encode(modelArtifact, forKey: .modelArtifact)
    }
}

package struct AcceleratorXPCWorkerExecuteResponse: Codable, Equatable, Sendable {
    package let protocolVersion: Int
    package let result: AcceleratorExecutionResult

    package init(result: AcceleratorExecutionResult) throws {
        self.protocolVersion = AcceleratorXPCContract.currentVersion
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case result
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try AcceleratorXPCValidation.exactKeys(
            Set(container.allKeys.map(\.stringValue)),
            expected: ["protocolVersion", "result"],
            field: "worker.response"
        )
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        try AcceleratorXPCValidation.version(protocolVersion)
        self.protocolVersion = protocolVersion
        self.result = try container.decode(
            AcceleratorExecutionResult.self,
            forKey: .result
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(result, forKey: .result)
    }
}

package struct AcceleratorXPCWorkerTerminationUncertain: Error, Sendable {}

package final class AcceleratorXPCProcessBackend: AcceleratorXPCBackend, @unchecked Sendable {
    private let workerExecutable: SecureExecutableIdentity
    private let workerArguments: [String]
    private let workingDirectory: String
    private let artifact: AcceleratorXPCModelArtifact
    private let terminationGraceMilliseconds: Int

    package init(
        workerExecutable: SecureExecutableIdentity,
        workerArguments: [String] = [],
        workingDirectory: String = "/",
        artifact: AcceleratorXPCModelArtifact,
        terminationGraceMilliseconds: Int = 1_000
    ) throws {
        guard workerExecutable.path.hasPrefix("/"),
              workerArguments.count <= 4_096,
              (10...5_000).contains(terminationGraceMilliseconds) else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: "worker")
        }
        for argument in workerArguments {
            guard !argument.contains("\0") else {
                throw AcceleratorXPCValidationError(code: .invalidPayload, field: "workerArguments")
            }
        }
        _ = try SecureExecutableResolver.verify(
            path: workerExecutable.path,
            ownershipPolicy: workerExecutable.ownershipPolicy
        )
        self.workerExecutable = workerExecutable
        self.workerArguments = workerArguments
        self.workingDirectory = workingDirectory
        self.artifact = artifact
        self.terminationGraceMilliseconds = terminationGraceMilliseconds
    }

    package func inventory(
        for query: AcceleratorXPCInventoryQuery
    ) async throws -> AcceleratorInventorySnapshot {
        throw AcceleratorXPCBackendError.unavailable
    }

    package func status(
        for query: AcceleratorXPCStatusQuery
    ) async throws -> AcceleratorXPCStatusSnapshot {
        throw AcceleratorXPCBackendError.unavailable
    }

    package func modelArtifact(
        for modelHash: AcceleratorDigest
    ) async throws -> AcceleratorXPCModelArtifact {
        guard modelHash == artifact.modelHash else {
            throw AcceleratorXPCBackendError.unavailable
        }
        return artifact
    }

    package func execute(
        _ context: AcceleratorXPCBackendExecutionContext
    ) async throws -> AcceleratorExecutionResult {
        guard context.modelArtifact.modelHash == artifact.modelHash else {
            throw AcceleratorXPCBackendError.unavailable
        }

        let request = try AcceleratorXPCWorkerExecuteRequest(context: context)
        let standardInput = try AcceleratorXPCWireJSON.encode(request)
        guard standardInput.count <= SecureSubprocessRequest.maximumInputBytes else {
            throw AcceleratorXPCBackendError.unavailable
        }

        let subprocessRequest = SecureSubprocessRequest(
            executablePath: workerExecutable.path,
            arguments: workerArguments,
            environment: SecureSubprocessEnvironment.minimal,
            workingDirectory: workingDirectory,
            standardInput: standardInput,
            timeoutMilliseconds: min(
                86_400_000,
                max(1_000, context.payload.request.timeoutMilliseconds + 1_000)
            ),
            terminationGraceMilliseconds: terminationGraceMilliseconds,
            maximumStandardOutputBytes: AcceleratorXPCContract.maxPayloadBytes,
            maximumStandardErrorBytes: 64 * 1_024,
            maximumStandardInputBytes: standardInput.count
        )
        do {
            try SecureExecutableResolver.verifyUnchanged(workerExecutable)
            let output = try await SecureSubprocessRunner().runAsync(subprocessRequest)
            try SecureExecutableResolver.verifyUnchanged(workerExecutable)
            guard output.exitStatus == 0,
                  output.terminationSignal == nil,
                  !output.standardOutputTruncated,
                  !output.standardErrorTruncated,
                  !output.standardOutput.isEmpty else {
                throw AcceleratorXPCBackendError.unavailable
            }
            let response = try AcceleratorXPCWireJSON.decode(
                AcceleratorXPCWorkerExecuteResponse.self,
                from: output.standardOutput
            )
            guard response.result.requestID == context.payload.request.requestID,
                  response.result.grantID == context.payload.request.grantID,
                  response.result.reservationID == context.payload.request.reservationID,
                  response.result.scope == context.payload.request.scope,
                  response.result.mode == context.payload.request.mode,
                  response.result.modelHash == context.payload.request.modelHash,
                  response.result.fence == context.payload.request.fence,
                  response.result.authenticatedBy == context.payload.request.authentication else {
                throw AcceleratorXPCBackendError.unavailable
            }
            return response.result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SecureSubprocessError {
            switch error {
            case .processTreeCleanupFailed:
                throw AcceleratorXPCWorkerTerminationUncertain()
            case .cancelled, .timedOut:
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw AcceleratorXPCBackendError.unavailable
            default:
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw AcceleratorXPCBackendError.unavailable
            }
        } catch is AcceleratorXPCBackendError {
            throw AcceleratorXPCBackendError.unavailable
        } catch {
            throw AcceleratorXPCBackendError.unavailable
        }
    }
}

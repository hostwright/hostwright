import Foundation

public protocol ContainerizationHelperInteractiveRequesting: Sendable {
    func interactiveCapabilitySnapshot() async throws -> RuntimeCapabilitySnapshot
    func interactiveInventory() async throws -> RuntimeInventory
    func interactiveResourceUsage(
        resourceIdentifier: String
    ) async throws -> RuntimeResourceUsageSnapshot
    func interactiveLogChunk(
        resourceIdentifier: String,
        lineLimit: Int,
        cursor: UInt64?,
        startAtEnd: Bool,
        maximumBytes: Int
    ) async throws -> ContainerizationHelperLogChunk
}

extension ContainerizationHelperClient: ContainerizationHelperInteractiveRequesting {
    public func interactiveCapabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        try await negotiate()
    }

    public func interactiveInventory() async throws -> RuntimeInventory {
        try await observe()
    }

    public func interactiveResourceUsage(
        resourceIdentifier: String
    ) async throws -> RuntimeResourceUsageSnapshot {
        try await resourceUsage(resourceIdentifier)
    }

    public func interactiveLogChunk(
        resourceIdentifier: String,
        lineLimit: Int,
        cursor: UInt64?,
        startAtEnd: Bool,
        maximumBytes: Int
    ) async throws -> ContainerizationHelperLogChunk {
        try await logChunk(
            resourceIdentifier,
            lineLimit: lineLimit,
            cursor: cursor,
            startAtEnd: startAtEnd,
            maximumBytes: maximumBytes
        )
    }
}

public struct ContainerizationHelperInteractiveExecutor: Sendable {
    private static let pollingIntervalMilliseconds = 100

    private let requester: any ContainerizationHelperInteractiveRequesting

    public init(requester: any ContainerizationHelperInteractiveRequesting) {
        self.requester = requester
    }

    public init(client: ContainerizationHelperClient) {
        self.init(requester: client)
    }

    public static func supportedOperations(
        in snapshot: RuntimeCapabilitySnapshot
    ) -> Set<RuntimeInteractiveOperationKind> {
        Set(
            RuntimeInteractiveOperationKind.allCases.filter {
                unavailableReason(for: $0, in: snapshot) == nil
            }
        )
    }

    public static func unavailableReason(
        for operation: RuntimeInteractiveOperationKind,
        in snapshot: RuntimeCapabilitySnapshot
    ) -> String? {
        guard snapshot.descriptor.providerID == .appleContainerization else {
            return "The selected provider is not the Apple Containerization helper."
        }
        guard [.inspect, .stats, .logsFollow].contains(operation) else {
            return "Containerization 0.35.0 does not expose \(operation.rawValue) through the qualified helper protocol."
        }
        guard snapshot.descriptor.components.contains(where: {
            $0.identifier == .containerizationHelperProtocolV1 &&
                $0.version == RuntimeProviderCapabilityContract.helperProtocolVersion
        }) else {
            return "The qualified Containerization helper protocol v1 component is unavailable."
        }
        guard snapshot.descriptor.components.contains(where: {
            $0.identifier == .appleContainerizationFramework &&
                $0.version == RuntimeProviderCapabilityContract.containerizationFrameworkVersion
        }) else {
            return "Containerization \(RuntimeProviderCapabilityContract.containerizationFrameworkVersion) is unavailable."
        }

        let required: [RuntimeProviderFeature]
        switch operation {
        case .inspect, .stats:
            required = [.observation]
        case .logsFollow:
            required = [.streaming, .cancellation]
        case .exec, .attach, .copyIn, .copyOut, .export:
            return "Containerization 0.35.0 does not expose \(operation.rawValue) through the qualified helper protocol."
        }

        for feature in required {
            let values = snapshot.features.filter { $0.feature == feature }
            guard values.count == 1 else {
                return "\(feature.rawValue) capability is missing or duplicated."
            }
            let status = values[0]
            guard status.state == .available, status.reason == .implemented else {
                return "\(feature.rawValue) capability is \(status.state.rawValue)/\(status.reason.rawValue)."
            }
        }
        return nil
    }

    public func execute(
        _ operation: RuntimeInteractiveOperation,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        timeoutMilliseconds: Int,
        control: RuntimeInteractiveProcessControl = RuntimeInteractiveProcessControl(),
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws -> RuntimeInteractiveExecutionResult {
        if let reason = Self.unavailableReason(for: operation.kind, in: capabilitySnapshot) {
            throw RuntimeInteractiveError.capabilityUnavailable(
                operation: operation.kind,
                reason: reason
            )
        }
        guard RuntimeManagedResourceIdentity.isCurrentIdentifier(
            operation.resourceIdentifier
        ) else {
            throw RuntimeInteractiveError.invalidResourceIdentifier
        }
        guard (1...86_400_000).contains(timeoutMilliseconds) else {
            throw RuntimeInteractiveError.invalidProcessArguments
        }

        let deadline = Date(
            timeIntervalSinceNow: Double(timeoutMilliseconds) / 1_000
        )
        try Self.requireActive(control: control, deadline: deadline)
        try await requireCurrentSnapshot(
            capabilitySnapshot,
            operation: operation.kind,
            control: control,
            deadline: deadline
        )

        var sequence: UInt64 = 0
        switch operation {
        case .inspect(let resourceIdentifier):
            let inventory = try await retryingSafeRead(
                capabilitySnapshot,
                operation: operation.kind,
                control: control,
                deadline: deadline
            ) {
                try await requester.interactiveInventory()
            }
            let matches = inventory.containers.filter {
                $0.runtimeID == resourceIdentifier || $0.name == resourceIdentifier
            }
            guard matches.count == 1,
                  matches[0].runtimeID == resourceIdentifier,
                  matches[0].name == resourceIdentifier else {
                throw RuntimeInteractiveError.invalidStructuredOutput
            }
            let output = ContainerizationHelperInspectOutput(
                capabilitySHA256: capabilitySnapshot.canonicalSHA256,
                inventorySHA256: inventory.semanticSHA256,
                container: matches[0]
            )
            try Self.emit(
                Self.canonicalRedactedJSON(output),
                sequence: &sequence,
                sink: sink
            )

        case .stats(let resourceIdentifier):
            let usage = try await retryingSafeRead(
                capabilitySnapshot,
                operation: operation.kind,
                control: control,
                deadline: deadline
            ) {
                try await requester.interactiveResourceUsage(
                    resourceIdentifier: resourceIdentifier
                )
            }
            guard usage.resourceIdentifier == resourceIdentifier else {
                throw RuntimeInteractiveError.invalidStructuredOutput
            }
            try Self.emit(
                Self.canonicalRedactedJSON(
                    ContainerizationHelperStatsOutput(
                        capabilitySHA256: capabilitySnapshot.canonicalSHA256,
                        usage: usage
                    )
                ),
                sequence: &sequence,
                sink: sink
            )

        case .logsFollow(let resourceIdentifier, let tail):
            try await followLogs(
                resourceIdentifier: resourceIdentifier,
                tail: min(max(0, tail), RuntimeProviderConformanceLimits.maximumLogLines),
                capabilitySnapshot: capabilitySnapshot,
                control: control,
                deadline: deadline,
                sequence: &sequence,
                sink: sink
            )

        case .exec, .attach, .copyIn, .copyOut, .export:
            throw RuntimeInteractiveError.capabilityUnavailable(
                operation: operation.kind,
                reason: "The Containerization helper does not expose this operation."
            )
        }

        try Self.emitEndOfStream(sequence: &sequence, sink: sink)
        return RuntimeInteractiveExecutionResult(
            operation: operation.kind,
            exitStatus: 0,
            emittedFrameCount: Int(sequence),
            standardErrorTail: ""
        )
    }

    private func followLogs(
        resourceIdentifier: String,
        tail: Int,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        control: RuntimeInteractiveProcessControl,
        deadline: Date,
        sequence: inout UInt64,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) async throws {
        var cursor: UInt64?
        var initialRead = true
        while true {
            try Self.requireActive(control: control, deadline: deadline)
            let chunk = try await retryingSafeRead(
                capabilitySnapshot,
                operation: .logsFollow,
                control: control,
                deadline: deadline
            ) {
                try await requester.interactiveLogChunk(
                    resourceIdentifier: resourceIdentifier,
                    lineLimit: max(1, tail),
                    cursor: cursor,
                    startAtEnd: initialRead && tail == 0,
                    maximumBytes: RuntimeStreamEnvelope.maximumChunkBytes
                )
            }
            guard chunk.resourceIdentifier == resourceIdentifier,
                  chunk.cursorEnd >= chunk.cursorStart,
                  cursor.map({ chunk.cursorStart == $0 }) ?? true else {
                throw RuntimeInteractiveError.invalidStructuredOutput
            }
            initialRead = false
            cursor = chunk.cursorEnd
            let redacted = RuntimeRedactionPolicy.default.redact(chunk.text)
            if !redacted.isEmpty {
                try Self.emit(Data(redacted.utf8), sequence: &sequence, sink: sink)
            }
            if !chunk.atCurrentEnd {
                continue
            }

            let inventory = try await retryingSafeRead(
                capabilitySnapshot,
                operation: .logsFollow,
                control: control,
                deadline: deadline
            ) {
                try await requester.interactiveInventory()
            }
            let matches = inventory.containers.filter {
                $0.runtimeID == resourceIdentifier || $0.name == resourceIdentifier
            }
            guard matches.count <= 1 else {
                throw RuntimeInteractiveError.invalidStructuredOutput
            }
            if matches.isEmpty || matches[0].lifecycle != .running {
                return
            }
            try await Self.poll(control: control, deadline: deadline)
        }
    }

    private func requireCurrentSnapshot(
        _ expected: RuntimeCapabilitySnapshot,
        operation: RuntimeInteractiveOperationKind,
        control: RuntimeInteractiveProcessControl,
        deadline: Date
    ) async throws {
        try Self.requireActive(control: control, deadline: deadline)
        let current: RuntimeCapabilitySnapshot
        do {
            current = try await requester.interactiveCapabilitySnapshot()
        } catch {
            throw Self.translate(error, operation: operation)
        }
        guard current.descriptor.providerID == .appleContainerization,
              current.canonicalSHA256 == expected.canonicalSHA256,
              Self.unavailableReason(for: operation, in: current) == nil else {
            throw RuntimeInteractiveError.capabilityUnavailable(
                operation: operation,
                reason: "The confirmed Containerization helper capability snapshot is stale."
            )
        }
    }

    private func retryingSafeRead<Value>(
        _ expected: RuntimeCapabilitySnapshot,
        operation: RuntimeInteractiveOperationKind,
        control: RuntimeInteractiveProcessControl,
        deadline: Date,
        body: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await body()
        } catch {
            guard Self.isRestartSafe(error) else {
                throw Self.translate(error, operation: operation)
            }
        }
        try Self.requireActive(control: control, deadline: deadline)
        try await requireCurrentSnapshot(
            expected,
            operation: operation,
            control: control,
            deadline: deadline
        )
        do {
            return try await body()
        } catch {
            throw Self.translate(error, operation: operation)
        }
    }

    private static func emit(
        _ data: Data,
        sequence: inout UInt64,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) throws {
        let frames = try RuntimeStreamEnvelope.chunks(
            data,
            stream: .standardOutput,
            startingAt: sequence
        )
        for frame in frames {
            try sink(frame)
        }
        sequence += UInt64(frames.count)
    }

    private static func emitEndOfStream(
        sequence: inout UInt64,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) throws {
        try sink(
            RuntimeStreamEnvelope(
                sequence: sequence,
                stream: .standardOutput,
                payload: Data(),
                endOfStream: true
            )
        )
        sequence += 1
        try sink(
            RuntimeStreamEnvelope(
                sequence: sequence,
                stream: .standardError,
                payload: Data(),
                endOfStream: true
            )
        )
        sequence += 1
    }

    private static func canonicalRedactedJSON<Output: Encodable>(
        _ output: Output
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(output)
        guard encoded.count <= RuntimeStreamEnvelope.maximumFrameBytes else {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
        do {
            let value = try JSONSerialization.jsonObject(with: encoded)
            let redacted = try JSONSerialization.data(
                withJSONObject: redactJSON(value),
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            guard redacted.count <= RuntimeStreamEnvelope.maximumFrameBytes else {
                throw RuntimeInteractiveError.invalidStructuredOutput
            }
            return redacted
        } catch let error as RuntimeInteractiveError {
            throw error
        } catch {
            throw RuntimeInteractiveError.invalidStructuredOutput
        }
    }

    private static func redactJSON(_ value: Any, key: String? = nil) -> Any {
        let policy = RuntimeRedactionPolicy.default
        if let key, policy.isSensitiveKey(key) {
            return policy.replacement
        }
        if let object = value as? [String: Any] {
            var redacted = Dictionary(
                uniqueKeysWithValues: object.map {
                    ($0.key, redactJSON($0.value, key: $0.key))
                }
            )
            let semanticKey = (object["name"] as? String) ?? (object["key"] as? String)
            if let semanticKey,
               policy.isSensitiveKey(semanticKey),
               object["value"] != nil {
                redacted["value"] = policy.replacement
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map { redactJSON($0) }
        }
        if let string = value as? String {
            return policy.redact(string)
        }
        return value
    }

    private static func poll(
        control: RuntimeInteractiveProcessControl,
        deadline: Date
    ) async throws {
        try requireActive(control: control, deadline: deadline)
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let milliseconds = min(
            pollingIntervalMilliseconds,
            max(1, Int(remaining * 1_000))
        )
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
        } catch {
            throw RuntimeInteractiveError.processCancelled
        }
    }

    private static func requireActive(
        control: RuntimeInteractiveProcessControl,
        deadline: Date
    ) throws {
        if Task.isCancelled || control.isCancelled {
            throw RuntimeInteractiveError.processCancelled
        }
        if deadline.timeIntervalSinceNow <= 0 {
            throw RuntimeInteractiveError.processTimedOut
        }
    }

    private static func isRestartSafe(_ error: Error) -> Bool {
        guard let error = error as? ContainerizationHelperClientError else {
            return false
        }
        switch error {
        case .socketUnavailable, .connectionFailed, .helperLaunchFailed, .helperExited:
            return true
        case .remote(let failure):
            return failure.retryDisposition == .safeAfterObservation &&
                [.unavailable, .crashed].contains(failure.category)
        default:
            return false
        }
    }

    private static func translate(
        _ error: Error,
        operation: RuntimeInteractiveOperationKind
    ) -> RuntimeInteractiveError {
        if let error = error as? RuntimeInteractiveError {
            return error
        }
        if error is CancellationError {
            return .processCancelled
        }
        guard let error = error as? ContainerizationHelperClientError else {
            return .processFailed(
                exitStatus: -1,
                diagnostic: "Containerization helper \(operation.rawValue) failed."
            )
        }
        switch error {
        case .cancelled:
            return .processCancelled
        case .timedOut:
            return .processTimedOut
        case .responseTooLarge:
            return .streamFrameTooLarge
        case .invalidResponse, .responseMismatch, .replayedResponse, .truncatedResponse:
            return .invalidStructuredOutput
        case .remote(let failure):
            switch failure.category {
            case .cancelled:
                return .processCancelled
            case .timedOut:
                return .processTimedOut
            case .invalidResponse, .outputLimited:
                return .invalidStructuredOutput
            case .unavailable, .incompatible, .permissionDenied, .staleCapability:
                return .capabilityUnavailable(
                    operation: operation,
                    reason: failure.diagnostic
                )
            default:
                return .processFailed(
                    exitStatus: -1,
                    diagnostic: failure.diagnostic
                )
            }
        default:
            return .processFailed(
                exitStatus: -1,
                diagnostic: "Containerization helper \(operation.rawValue) failed."
            )
        }
    }
}

private struct ContainerizationHelperInspectOutput: Encodable {
    let schemaVersion = 1
    let providerID = RuntimeProviderID.appleContainerization.rawValue
    let capabilitySHA256: String
    let inventorySHA256: String
    let container: RuntimeInventoryContainer
}

private struct ContainerizationHelperStatsOutput: Encodable {
    let schemaVersion = 1
    let providerID = RuntimeProviderID.appleContainerization.rawValue
    let capabilitySHA256: String
    let resourceIdentifier: String
    let cpuUsageMicroseconds: UInt64
    let memoryUsageBytes: UInt64
    let memoryLimitBytes: UInt64
    let networkReceiveBytes: UInt64
    let networkTransmitBytes: UInt64
    let blockReadBytes: UInt64
    let blockWriteBytes: UInt64
    let processCount: Int

    init(capabilitySHA256: String, usage: RuntimeResourceUsageSnapshot) {
        self.capabilitySHA256 = capabilitySHA256
        self.resourceIdentifier = usage.resourceIdentifier
        self.cpuUsageMicroseconds = usage.cpuUsageMicroseconds
        self.memoryUsageBytes = usage.memoryUsageBytes
        self.memoryLimitBytes = usage.memoryLimitBytes
        self.networkReceiveBytes = usage.networkReceiveBytes
        self.networkTransmitBytes = usage.networkTransmitBytes
        self.blockReadBytes = usage.blockReadBytes
        self.blockWriteBytes = usage.blockWriteBytes
        self.processCount = usage.processCount
    }
}

import Combine
import Foundation
import HostwrightCommandTransport
import HostwrightControlPlane
import HostwrightControlTransport
import HostwrightDaemonCore
import HostwrightRuntime

private enum DesktopModelBoundary {
    static func safeCode(_ value: String?, fallback: String) -> String {
        guard let value,
            value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$", options: .regularExpression) != nil
        else { return fallback }
        return value
    }

    static func redactedMessage(_ value: String?, fallback: String) -> String {
        let source = value ?? fallback
        let redacted = RuntimeRedactionPolicy.default
            .redact(source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { return fallback }
        return String(redacted.prefix(256))
    }
}

public struct DesktopControlAPIClient: Sendable {
    public let transport: any DesktopControlTransport

    public init(transport: any DesktopControlTransport) {
        self.transport = transport
    }

    public func daemonHealth() throws -> DesktopDaemonHealth {
        let route = try CLIControlRoute.classify(
            arguments: ["daemon", "status", "--output", "json"]
        )
        let request = makeRequest(
            operation: route.operation,
            body: route.requestBody(),
            timeoutMilliseconds: 30_000,
            prefix: "daemon"
        )
        let response = try transport.send(request)
        let result = try CLIControlResultContract.result(from: checkedResponse(response, for: request))
        guard result.exitCode == 0 else {
            throw DesktopControlFailure(
                code: "daemon.status.failed",
                message: DesktopModelBoundary.redactedMessage(
                    result.standardError,
                    fallback: "Daemon health is unavailable."
                )
            )
        }
        do {
            let lifecycle = try JSONDecoder().decode(
                DaemonLifecycleResult.self,
                from: Data(result.standardOutput.utf8)
            )
            return DesktopDaemonHealth(
                readiness: lifecycle.status.readiness.rawValue,
                reasonCode: lifecycle.status.reasonCode.rawValue,
                label: lifecycle.status.label,
                domain: lifecycle.status.domain,
                generation: lifecycle.status.generation,
                processID: lifecycle.status.processID
            )
        } catch {
            throw DesktopControlFailure(
                code: "daemon.status.invalidResponse",
                message: "The daemon returned an invalid health document."
            )
        }
    }

    public func projectStatus() throws -> DesktopProjectStatus {
        let request = makeRequest(
            operation: "status",
            timeoutMilliseconds: ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
            prefix: "status"
        )
        let response = try transport.send(request)
        let result = try checkedResult(checkedResponse(response, for: request))
        do {
            let payload = try decode(StatusPayload.self, from: result)
            guard let projectName = payload.project, !projectName.isEmpty,
                payload.manifest.valid, payload.manifest.exists
            else {
                throw DesktopControlFailure(
                    code: "status.invalidResponse",
                    message: "The daemon returned an incomplete project status."
                )
            }
            let services = payload.services.map { service in
                let observed = service.observed ?? service.instances?.first
                return DesktopServiceStatus(
                    id: service.name,
                    desiredImage: service.desiredImage,
                    resourceIdentifier: observed?.resourceIdentifier,
                    observedImage: observed?.image,
                    lifecycle: observed?.lifecycle,
                    health: observed?.health
                )
            }
            return DesktopProjectStatus(
                id: "project-\(projectName)",
                name: projectName,
                manifestPath: payload.manifest.path,
                manifestIsValid: payload.manifest.valid && payload.manifest.exists,
                services: services,
                planHash: payload.planHash
            )
        } catch let failure as DesktopControlFailure {
            throw failure
        } catch {
            throw DesktopControlFailure(
                code: "status.invalidResponse",
                message: "The daemon returned an invalid project status."
            )
        }
    }

    public func connectSession() throws -> any DesktopControlSession {
        try transport.connectSession()
    }

    private func checkedResponse(
        _ response: ControlResponseEnvelope,
        for request: ControlRequestEnvelope
    ) throws -> ControlResponseEnvelope {
        guard response.requestID == request.requestID else {
            throw DesktopControlFailure(
                code: "control.invalidResponse",
                message: "The control response did not match its request."
            )
        }
        do {
            try response.validate()
        } catch {
            throw DesktopControlFailure(
                code: "control.invalidResponse",
                message: "The control response failed protocol validation."
            )
        }
        guard response.status == .completed else {
            let error = response.error
            throw DesktopControlFailure(
                code: DesktopModelBoundary.safeCode(
                    error?.code,
                    fallback: "control.requestFailed"
                ),
                message: DesktopModelBoundary.redactedMessage(
                    error?.message,
                    fallback: "The control request did not complete."
                )
            )
        }
        return response
    }

    private func checkedResult(_ response: ControlResponseEnvelope) throws -> ControlPlaneJSONValue {
        guard let result = response.result else {
            throw DesktopControlFailure(
                code: "control.emptyResult",
                message: "The control request returned no result."
            )
        }
        return result
    }

    private func makeRequest(
        operation: String,
        body: ControlPlaneJSONValue? = nil,
        timeoutMilliseconds: Int,
        prefix: String
    ) -> ControlRequestEnvelope {
        ControlRequestEnvelope(
            requestID: "desktop-\(prefix)-\(UUID().uuidString.lowercased())",
            operation: operation,
            timeoutMilliseconds: timeoutMilliseconds,
            body: body
        )
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from value: ControlPlaneJSONValue
    ) throws -> T {
        try JSONDecoder().decode(
            type,
            from: ControlPlaneCanonicalJSON.encode(value)
        )
    }
}

@MainActor
public final class DesktopOperationsModel: ObservableObject {
    @Published public private(set) var connectionState: DesktopConnectionState
    @Published public private(set) var daemonHealth: DesktopDaemonHealth?
    @Published public private(set) var projects: [DesktopProjectStatus] = []
    @Published public private(set) var events: [DesktopEvent] = []
    @Published public private(set) var logChunks: [DesktopLogChunk] = []
    @Published public private(set) var lastFailure: DesktopControlFailure?
    @Published public private(set) var isEventStreamRunning = false
    @Published public private(set) var isLogStreamRunning = false

    public let endpoint: DesktopControlEndpoint?
    private let api: DesktopControlAPIClient
    private let reconnectDelaysMilliseconds: [UInt64]
    private var reconnectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?

    public init(
        endpoint: DesktopControlEndpoint? = nil,
        transport: any DesktopControlTransport,
        reconnectDelaysMilliseconds: [UInt64] = [250, 1_000, 2_000, 5_000]
    ) {
        self.endpoint = endpoint
        self.api = DesktopControlAPIClient(transport: transport)
        self.reconnectDelaysMilliseconds = reconnectDelaysMilliseconds.isEmpty
            ? [1_000]
            : reconnectDelaysMilliseconds.map { min($0, 60_000) }
        self.connectionState = .disconnected
    }

    public static func live(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        do {
            let endpoint = try DesktopControlEndpoint.discover(
                homeDirectory: homeDirectory,
                environment: environment
            )
            return Self(
                endpoint: endpoint,
                transport: PersistentDesktopControlTransport(endpoint: endpoint)
            )
        } catch {
            let failure = DesktopControlFailure(
                code: "discovery.invalidEndpoint",
                message: "Hostwright's local control endpoint is unavailable."
            )
            return Self(
                transport: UnavailableDesktopControlTransport(failure: failure),
                initialFailure: failure
            )
        }
    }

    private init(
        transport: any DesktopControlTransport,
        initialFailure: DesktopControlFailure
    ) {
        self.endpoint = nil
        self.api = DesktopControlAPIClient(transport: transport)
        self.reconnectDelaysMilliseconds = [1_000]
        self.connectionState = .unavailable(initialFailure)
        self.lastFailure = initialFailure
    }

    public func connect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.connectOnce()
        }
    }

    public func reconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for (index, delay) in reconnectDelaysMilliseconds.enumerated() {
                if index > 0 {
                    connectionState = .reconnecting(
                        attempt: index + 1,
                        delayMilliseconds: delay
                    )
                    do {
                        try await Task.sleep(nanoseconds: delay * 1_000_000)
                    } catch {
                        return
                    }
                }
                await connectOnce()
                if case .connected = connectionState {
                    return
                }
            }
        }
    }

    public func disconnect() {
        reconnectTask?.cancel()
        eventTask?.cancel()
        logTask?.cancel()
        reconnectTask = nil
        eventTask = nil
        logTask = nil
        isEventStreamRunning = false
        isLogStreamRunning = false
        connectionState = .disconnected
    }

    public func refreshStatus() {
        let api = self.api
        Task { [weak self] in
            do {
                let project = try await Task.detached {
                    try api.projectStatus()
                }.value
                guard !Task.isCancelled else { return }
                self?.apply(project: project)
            } catch is CancellationError {
                return
            } catch {
                self?.record(error: Self.failure(from: error))
            }
        }
    }

    public func startEventStream(filter: DesktopEventFilter = .init()) {
        eventTask?.cancel()
        isEventStreamRunning = true
        let api = self.api
        eventTask = Task { [weak self] in
            let reader = Task.detached {
                try Self.readEvents(api: api, filter: filter)
            }
            defer { reader.cancel() }
            do {
                let values = try await withTaskCancellationHandler(operation: {
                    try await reader.value
                }, onCancel: {
                    reader.cancel()
                })
                guard !Task.isCancelled else { return }
                self?.events = Array(values.suffix(500))
                self?.isEventStreamRunning = false
            } catch is CancellationError {
                self?.isEventStreamRunning = false
            } catch {
                self?.isEventStreamRunning = false
                self?.record(error: Self.failure(from: error))
            }
        }
    }

    public func openLogStream(for serviceID: String, tail: Int = 100) {
        logTask?.cancel()
        guard let project = projects.first,
            let service = project.services.first(where: { $0.id == serviceID }),
            let target = service.resourceIdentifier
        else {
            record(error: DesktopControlFailure(
                code: "logs.unavailable",
                message: "This service has no observed runtime resource for logs."
            ))
            return
        }
        guard (1...1_000).contains(tail) else {
            record(error: DesktopControlFailure(
                code: "logs.invalidRequest",
                message: "The requested log tail is outside the supported bound."
            ))
            return
        }
        isLogStreamRunning = true
        logChunks = []
        let api = self.api
        let manifestPath = project.manifestPath
        logTask = Task { [weak self] in
            let reader = Task.detached {
                try Self.readLogs(
                    api: api,
                    target: target,
                    manifestPath: manifestPath,
                    serviceName: serviceID,
                    tail: tail
                )
            }
            defer { reader.cancel() }
            do {
                let values = try await withTaskCancellationHandler(operation: {
                    try await reader.value
                }, onCancel: {
                    reader.cancel()
                })
                guard !Task.isCancelled else { return }
                self?.logChunks = values
                self?.isLogStreamRunning = false
            } catch is CancellationError {
                self?.isLogStreamRunning = false
            } catch {
                self?.isLogStreamRunning = false
                self?.record(error: Self.failure(from: error))
            }
        }
    }

    public func cancelStreams() {
        eventTask?.cancel()
        logTask?.cancel()
        isEventStreamRunning = false
        isLogStreamRunning = false
    }

    private func connectOnce() async {
        connectionState = .connecting
        let api = self.api
        do {
            let health = try await Task.detached {
                try api.daemonHealth()
            }.value
            guard !Task.isCancelled else { return }
            daemonHealth = health
            connectionState = .connected
            do {
                let project = try await Task.detached {
                    try api.projectStatus()
                }.value
                guard !Task.isCancelled else { return }
                apply(project: project)
            } catch is CancellationError {
                return
            } catch {
                record(error: Self.failure(from: error))
            }
        } catch is CancellationError {
            return
        } catch {
            let failure = Self.failure(from: error)
            connectionState = .unavailable(failure)
            lastFailure = failure
        }
    }

    private func apply(project: DesktopProjectStatus) {
        projects = [project]
        lastFailure = nil
    }

    private func record(error: DesktopControlFailure) {
        lastFailure = error
        if error.code.hasPrefix("transport.") || error.code.hasPrefix("discovery.") {
            connectionState = .unavailable(error)
        }
    }

    nonisolated private static func readEvents(
        api: DesktopControlAPIClient,
        filter: DesktopEventFilter
    ) throws -> [DesktopEvent] {
        let request = try filter.controlStreamRequest()
        let session = try api.connectSession()
        let streamID = "desktop-events-\(UUID().uuidString.lowercased())"
        var terminal = false
        defer {
            if !terminal {
                try? session.cancel(streamID: streamID)
            }
            session.close()
        }
        try session.openStream(
            streamID: streamID,
            request: request,
            cursor: filter.cursor,
            initialCredit: 32
        )

        var values: [DesktopEvent] = []
        while !Task.isCancelled {
            let frame: StreamFrame
            do {
                frame = try session.nextFrame(
                    streamID: streamID,
                    timeoutMilliseconds: 1_000
                )
            } catch PersistentControlClientError.deadlineExceeded {
                continue
            }
            switch frame.kind {
            case .open, .heartbeat, .ack:
                continue
            case .data:
                guard let payload = frame.payload else {
                    throw DesktopControlFailure(
                        code: "events.invalidFrame",
                        message: "The event stream returned an empty data frame."
                    )
                }
                values.append(try decodeEvent(payload))
                try session.acknowledge(
                    streamID: streamID,
                    credit: 1,
                    cursor: frame.cursor
                )
            case .end:
                terminal = true
                return values
            case .gap:
                terminal = true
                throw gapFailure(frame)
            case .error:
                terminal = true
                throw frameFailure(frame, fallbackCode: "events.streamFailed")
            case .cancel:
                terminal = true
                throw DesktopControlFailure(
                    code: "events.cancelled",
                    message: "The event stream was cancelled by the daemon."
                )
            }
        }
        throw CancellationError()
    }

    nonisolated private static func readLogs(
        api: DesktopControlAPIClient,
        target: String,
        manifestPath: String,
        serviceName: String,
        tail: Int
    ) throws -> [DesktopLogChunk] {
        let request = ControlStreamOpenRequest(
            source: .logs,
            target: target,
            filter: .object([
                "manifestPath": .string(manifestPath),
                "serviceName": .string(serviceName),
                "tail": .integer(Int64(tail)),
            ])
        )
        let session = try api.connectSession()
        let streamID = "desktop-logs-\(UUID().uuidString.lowercased())"
        var terminal = false
        defer {
            if !terminal {
                try? session.cancel(streamID: streamID)
            }
            session.close()
        }
        try session.openStream(
            streamID: streamID,
            request: request,
            cursor: nil,
            initialCredit: 16
        )

        var values: [DesktopLogChunk] = []
        var byteCount = 0
        while !Task.isCancelled {
            let frame: StreamFrame
            do {
                frame = try session.nextFrame(
                    streamID: streamID,
                    timeoutMilliseconds: 1_000
                )
            } catch PersistentControlClientError.deadlineExceeded {
                continue
            }
            switch frame.kind {
            case .open, .heartbeat, .ack:
                continue
            case .data:
                guard let payload = frame.payload else {
                    throw DesktopControlFailure(
                        code: "logs.invalidFrame",
                        message: "The log stream returned an empty data frame."
                    )
                }
                let chunk = try decodeLogChunk(payload)
                byteCount += chunk.text.utf8.count
                guard byteCount <= 4 * 1_024 * 1_024 else {
                    throw DesktopControlFailure(
                        code: "logs.responseTooLarge",
                        message: "The bounded log response exceeded the desktop buffer limit."
                    )
                }
                values.append(chunk)
                try session.acknowledge(
                    streamID: streamID,
                    credit: 1,
                    cursor: frame.cursor
                )
            case .end:
                terminal = true
                return values
            case .gap:
                terminal = true
                throw gapFailure(frame)
            case .error:
                terminal = true
                throw frameFailure(frame, fallbackCode: "logs.streamFailed")
            case .cancel:
                terminal = true
                throw DesktopControlFailure(
                    code: "logs.cancelled",
                    message: "The log stream was cancelled by the daemon."
                )
            }
        }
        throw CancellationError()
    }

    nonisolated private static func decodeEvent(_ payload: ControlPlaneJSONValue) throws -> DesktopEvent {
        do {
            let value = try decode(WireEvent.self, from: payload)
            return DesktopEvent(
                id: value.id,
                position: value.position,
                timestamp: value.timestamp,
                severity: value.severity,
                type: value.type,
                source: value.source,
                projectID: value.projectID,
                serviceName: value.serviceName,
                runtimeAdapter: value.runtimeAdapter,
                message: value.message,
                payloadJSONRedacted: value.payloadJSONRedacted,
                eventReference: value.eventReference,
                operationReferences: value.operationReferences
            )
        } catch {
            throw DesktopControlFailure(
                code: "events.invalidPayload",
                message: "The event stream returned an invalid event payload."
            )
        }
    }

    nonisolated private static func decodeLogChunk(_ payload: ControlPlaneJSONValue) throws -> DesktopLogChunk {
        do {
            let value = try decode(WireLogChunk.self, from: payload)
            guard value.encoding == "base64", let data = Data(base64Encoded: value.payload) else {
                throw DesktopControlFailure(
                    code: "logs.invalidPayload",
                    message: "The log stream returned an unsupported payload encoding."
                )
            }
            return DesktopLogChunk(
                id: value.ordinal,
                text: String(decoding: data, as: UTF8.self)
            )
        } catch let failure as DesktopControlFailure {
            throw failure
        } catch {
            throw DesktopControlFailure(
                code: "logs.invalidPayload",
                message: "The log stream returned an invalid log payload."
            )
        }
    }

    nonisolated private static func decode<T: Decodable>(
        _ type: T.Type,
        from value: ControlPlaneJSONValue
    ) throws -> T {
        try JSONDecoder().decode(type, from: ControlPlaneCanonicalJSON.encode(value))
    }

    nonisolated private static func gapFailure(_ frame: StreamFrame) -> DesktopControlFailure {
        let reason: String
        if let payload = frame.payload,
            let gap = try? decode(ControlStreamGap.self, from: payload),
            gap.reason.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil
        {
            reason = gap.reason
        } else {
            reason = "unknown"
        }
        return DesktopControlFailure(
            code: "stream.cursorGap",
            message: "The stream cursor is no longer replayable (\(reason))."
        )
    }

    nonisolated private static func frameFailure(
        _ frame: StreamFrame,
        fallbackCode: String
    ) -> DesktopControlFailure {
        DesktopControlFailure(
            code: safeCode(frame.error?.code, fallback: fallbackCode),
            message: redactedMessage(
                frame.error?.message,
                fallback: "The daemon stream failed safely."
            )
        )
    }

    nonisolated private static func failure(from error: Error) -> DesktopControlFailure {
        if let failure = error as? DesktopControlFailure {
            return failure
        }
        if let transportError = error as? PersistentControlClientError {
            let code: String
            switch transportError {
            case .unsafeSocket: code = "transport.unsafeSocket"
            case .connectionFailed: code = "transport.connectionFailed"
            case .serverBindingMismatch: code = "transport.serverBindingMismatch"
            case .credentialRequired: code = "transport.credentialRequired"
            case .invalidResponse: code = "transport.invalidResponse"
            case .concurrencyLimit: code = "transport.concurrencyLimit"
            case .streamLimit: code = "transport.streamLimit"
            case .deadlineExceeded: code = "transport.deadlineExceeded"
            case .connectionClosed: code = "transport.connectionClosed"
            }
            return DesktopControlFailure(
                code: code,
                message: "The local Hostwright control connection is unavailable."
            )
        }
        return DesktopControlFailure(
            code: "control.clientFailure",
            message: "The local Hostwright control request could not complete."
        )
    }

    nonisolated private static func safeCode(_ value: String?, fallback: String) -> String {
        guard let value,
            value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$", options: .regularExpression) != nil
        else { return fallback }
        return value
    }

    nonisolated private static func redactedMessage(_ value: String?, fallback: String) -> String {
        let source = value ?? fallback
        let redacted = RuntimeRedactionPolicy.default
            .redact(source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { return fallback }
        return String(redacted.prefix(256))
    }
}

public extension DesktopEventFilter {
    func controlStreamRequest() throws -> ControlStreamOpenRequest {
        var fields: [String: ControlPlaneJSONValue] = [:]
        try addString(projectID, key: "projectID", to: &fields)
        try addString(type, key: "type", to: &fields)
        try addString(serviceName, key: "serviceName", to: &fields)
        if let severity {
            guard ["info", "warning", "error"].contains(severity) else {
                throw DesktopControlFailure(
                    code: "events.invalidFilter",
                    message: "The event severity filter is unsupported."
                )
            }
            fields["severity"] = .string(severity)
        }
        if let maximumEvents {
            guard (1...1_001).contains(maximumEvents) else {
                throw DesktopControlFailure(
                    code: "events.invalidFilter",
                    message: "The event limit is outside the supported bound."
                )
            }
            fields["maximumEvents"] = .integer(Int64(maximumEvents))
        }
        guard !waitForFirst || endAfterSnapshot else {
            throw DesktopControlFailure(
                code: "events.invalidFilter",
                message: "Waiting for the first event requires a bounded snapshot."
            )
        }
        fields["endAfterSnapshot"] = .bool(endAfterSnapshot)
        fields["waitForFirst"] = .bool(waitForFirst)
        if let cursor {
            guard !cursor.isEmpty, cursor.utf8.count <= ControlPlaneContract.maximumStreamCursorBytes else {
                throw DesktopControlFailure(
                    code: "events.invalidFilter",
                    message: "The event cursor is outside the supported bound."
                )
            }
        }
        return ControlStreamOpenRequest(
            source: .events,
            filter: fields.isEmpty ? nil : .object(fields)
        )
    }

    private func addString(
        _ value: String?,
        key: String,
        to fields: inout [String: ControlPlaneJSONValue]
    ) throws {
        guard let value else { return }
        guard !value.isEmpty, value.utf8.count <= 256,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw DesktopControlFailure(
                code: "events.invalidFilter",
                message: "The event filter contains an invalid value."
            )
        }
        fields[key] = .string(value)
    }
}

private struct StatusPayload: Decodable {
    let manifest: Manifest
    let project: String?
    let planHash: String?
    let services: [Service]

    struct Manifest: Decodable {
        let path: String
        let valid: Bool
        let exists: Bool
    }

    struct Service: Decodable {
        let name: String
        let desiredImage: String?
        let observed: Observed?
        let instances: [Observed]?
    }

    struct Observed: Decodable {
        let resourceIdentifier: String
        let image: String?
        let lifecycle: String
        let health: String
    }
}

private struct WireEvent: Decodable {
    let position: Int64
    let id: String
    let timestamp: String
    let severity: String
    let type: String
    let source: String
    let projectID: String?
    let serviceName: String?
    let runtimeAdapter: String?
    let message: String
    let payloadJSONRedacted: String
    let eventReference: String
    let operationReferences: [String]
}

private struct WireLogChunk: Decodable {
    let ordinal: Int64
    let encoding: String
    let payload: String
}

private struct UnavailableDesktopControlTransport: DesktopControlTransport {
    let failure: DesktopControlFailure

    func send(_ request: ControlRequestEnvelope) throws -> ControlResponseEnvelope {
        throw failure
    }

    func connectSession() throws -> any DesktopControlSession {
        throw failure
    }
}

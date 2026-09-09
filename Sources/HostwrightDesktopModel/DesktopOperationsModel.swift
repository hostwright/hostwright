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

private struct DesktopLifecyclePlanWire: Decodable {
    let schemaVersion: Int
    let command: String
    let manifestSHA256: String
    let observationSHA256: String
    let planSHA256: String
    let projectName: String
    let nodes: [Node]

    struct Node: Decodable {
        let key: String
        let action: String
        let serviceName: String
        let resourceIdentifier: String
    }
}

private struct DesktopLifecycleResultWire: Decodable {
    let checkpoint: String
    let completedNodeKeys: [String]
    let groupID: String
    let kind: String
    let planSHA256: String
    let status: String
}

private struct DesktopLifecycleCLIResult {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
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

    public func lifecyclePreview(
        action: DesktopLifecycleAction,
        manifestPath: String,
        cancellation: PersistentControlRequestCancellation
    ) throws -> DesktopLifecyclePlanReview {
        let result = try lifecycleCLIResult(
            arguments: [action.rawValue, manifestPath, "--dry-run", "--output", "json"],
            cancellation: cancellation,
            prefix: "lifecycle-preview"
        )
        let wire: DesktopLifecyclePlanWire
        do {
            wire = try JSONDecoder().decode(
                DesktopLifecyclePlanWire.self,
                from: Data(result.standardOutput.utf8)
            )
        } catch {
            throw DesktopControlFailure(
                code: "lifecycle.invalidPlan",
                message: "The daemon returned an invalid lifecycle plan."
            )
        }
        guard wire.schemaVersion == 1,
              wire.command == action.rawValue,
              wire.nodes.count <= 1_024,
              Self.isSHA256(wire.manifestSHA256),
              Self.isSHA256(wire.observationSHA256),
              Self.isSHA256(wire.planSHA256),
              !wire.projectName.isEmpty,
              wire.projectName.utf8.count <= 128,
              URL(fileURLWithPath: manifestPath).standardizedFileURL.path == manifestPath else {
            throw DesktopControlFailure(
                code: "lifecycle.invalidPlan",
                message: "The daemon returned an invalid lifecycle plan."
            )
        }
        return DesktopLifecyclePlanReview(
            action: action,
            manifestPath: manifestPath,
            manifestSHA256: wire.manifestSHA256,
            observationSHA256: wire.observationSHA256,
            planSHA256: wire.planSHA256,
            projectName: wire.projectName,
            nodes: wire.nodes.map {
                DesktopLifecyclePlanNode(
                    key: $0.key,
                    action: $0.action,
                    serviceName: $0.serviceName,
                    resourceIdentifier: $0.resourceIdentifier
                )
            }
        )
    }

    public func executeLifecycle(
        plan: DesktopLifecyclePlanReview,
        cancellation: PersistentControlRequestCancellation
    ) throws -> DesktopLifecycleExecutionResult {
        let result = try lifecycleCLIResult(
            arguments: [
                plan.action.rawValue,
                plan.manifestPath,
                "--confirm-plan", plan.planSHA256,
                "--output", "json",
            ],
            cancellation: cancellation,
            prefix: "lifecycle-execute"
        )
        let wire: DesktopLifecycleResultWire
        do {
            wire = try JSONDecoder().decode(
                DesktopLifecycleResultWire.self,
                from: Data(result.standardOutput.utf8)
            )
        } catch {
            throw DesktopControlFailure(
                code: "lifecycle.invalidResult",
                message: "The daemon returned an invalid lifecycle result."
            )
        }
        guard wire.kind == "lifecycle-result",
              wire.status == "succeeded",
              wire.checkpoint == "verified",
              wire.planSHA256 == plan.planSHA256,
              Self.isUUID(wire.groupID),
              wire.completedNodeKeys.count <= 1_024 else {
            throw DesktopControlFailure(
                code: "lifecycle.invalidResult",
                message: "The daemon returned an invalid lifecycle result."
            )
        }
        return DesktopLifecycleExecutionResult(
            action: plan.action,
            groupID: wire.groupID,
            planSHA256: wire.planSHA256,
            completedNodeKeys: wire.completedNodeKeys
        )
    }

    private func lifecycleCLIResult(
        arguments: [String],
        cancellation: PersistentControlRequestCancellation,
        prefix: String
    ) throws -> DesktopLifecycleCLIResult {
        let route = try CLIControlRoute.classify(arguments: arguments)
        guard route.transport == .persistentControlAPI else {
            throw DesktopControlFailure(
                code: "lifecycle.invalidRoute",
                message: "The lifecycle action is unavailable through the local control endpoint."
            )
        }
        let request = makeRequest(
            operation: route.operation,
            body: route.requestBody(),
            timeoutMilliseconds: ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
            prefix: prefix
        )
        let response = try transport.send(request, cancellation: cancellation)
        let result = try CLIControlResultContract.result(
            from: checkedResponse(response, for: request)
        )
        guard result.exitCode == 0 else {
            throw DesktopControlFailure(
                code: "lifecycle.requestFailed",
                message: DesktopModelBoundary.redactedMessage(
                    result.standardError,
                    fallback: "The lifecycle request failed safely."
                )
            )
        }
        return DesktopLifecycleCLIResult(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            exitCode: result.exitCode
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func isUUID(_ value: String) -> Bool {
        value.range(
            of: "^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$",
            options: .regularExpression
        ) != nil
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
    @Published public private(set) var lifecycleState: DesktopLifecycleState = .idle

    public let endpoint: DesktopControlEndpoint?
    private let api: DesktopControlAPIClient
    private let reconnectDelaysMilliseconds: [UInt64]
    private var reconnectTask: Task<Void, Never>?
    private var connectionID: UUID?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var eventTask: Task<Void, Never>?
    private var eventID: UUID?
    private var logTask: Task<Void, Never>?
    private var logID: UUID?
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleID: UUID?
    private var lifecycleCancellation: PersistentControlRequestCancellation?

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
        invalidateLifecycleForConnectionChange()
        cancelStatusRefresh()
        reconnectTask?.cancel()
        let connectionID = UUID()
        self.connectionID = connectionID
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionID == connectionID {
                    self.reconnectTask = nil
                    self.connectionID = nil
                }
            }
            await self.connectOnce(connectionID: connectionID)
        }
    }

    public func reconnect() {
        invalidateLifecycleForConnectionChange()
        cancelStatusRefresh()
        reconnectTask?.cancel()
        let connectionID = UUID()
        self.connectionID = connectionID
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionID == connectionID {
                    self.reconnectTask = nil
                    self.connectionID = nil
                }
            }
            for (index, delay) in reconnectDelaysMilliseconds.enumerated() {
                guard !Task.isCancelled, self.connectionID == connectionID else { return }
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
                await connectOnce(connectionID: connectionID)
                guard !Task.isCancelled, self.connectionID == connectionID else { return }
                if case .connected = connectionState {
                    return
                }
            }
        }
    }

    public func disconnect() {
        invalidateLifecycleForConnectionChange()
        reconnectTask?.cancel()
        connectionID = nil
        cancelStatusRefresh()
        cancelEventStream()
        cancelLogStream()
        reconnectTask = nil
        connectionState = .disconnected
    }

    public func previewLifecycle(
        _ action: DesktopLifecycleAction,
        manifestPath: String
    ) {
        guard case .connected = connectionState else {
            record(error: DesktopControlFailure(
                code: "lifecycle.disconnected",
                message: "Connect to the local daemon before reviewing a lifecycle action."
            ))
            return
        }
        guard lifecycleTask == nil else { return }
        switch lifecycleState {
        case .awaitingConfirmation, .executing, .previewing:
            return
        case .idle, .succeeded, .cancelled:
            break
        }
        guard let project = projects.first(where: {
            $0.manifestPath == manifestPath && $0.manifestIsValid
        }) else {
            record(error: DesktopControlFailure(
                code: "lifecycle.invalidManifestSelection",
                message: "Select the daemon's current valid manifest before reviewing this action."
            ))
            return
        }

        let lifecycleID = UUID()
        let cancellation = PersistentControlRequestCancellation()
        let api = self.api
        self.lifecycleID = lifecycleID
        self.lifecycleCancellation = cancellation
        lifecycleState = .previewing(action)
        lastFailure = nil
        lifecycleTask = Task { [weak self] in
            let request = Task.detached {
                try api.lifecyclePreview(
                    action: action,
                    manifestPath: project.manifestPath,
                    cancellation: cancellation
                )
            }
            defer {
                request.cancel()
                if let self, self.lifecycleID == lifecycleID {
                    self.lifecycleTask = nil
                    self.lifecycleCancellation = nil
                }
            }
            do {
                let plan = try await withTaskCancellationHandler(operation: {
                    try await request.value
                }, onCancel: {
                    cancellation.cancel()
                    request.cancel()
                })
                guard !Task.isCancelled, let self, self.lifecycleID == lifecycleID,
                      case .connected = self.connectionState else { return }
                self.lifecycleState = .awaitingConfirmation(plan)
            } catch {
                guard !Task.isCancelled, let self, self.lifecycleID == lifecycleID else { return }
                self.lifecycleState = .idle
                self.record(error: Self.failure(from: error))
            }
        }
    }

    public func confirmLifecycle(planSHA256: String) {
        guard case .connected = connectionState,
              case .awaitingConfirmation(let plan) = lifecycleState,
              plan.planSHA256 == planSHA256,
              projects.contains(where: {
                  $0.manifestPath == plan.manifestPath && $0.manifestIsValid
              }),
              lifecycleTask == nil else {
            if case .awaitingConfirmation = lifecycleState {
                lifecycleState = .idle
                record(error: DesktopControlFailure(
                    code: "lifecycle.staleConfirmation",
                    message: "The lifecycle plan is stale. Review a fresh plan before confirming."
                ))
            }
            return
        }

        let lifecycleID = UUID()
        let cancellation = PersistentControlRequestCancellation()
        let api = self.api
        self.lifecycleID = lifecycleID
        self.lifecycleCancellation = cancellation
        lifecycleState = .executing(plan)
        lastFailure = nil
        lifecycleTask = Task { [weak self] in
            let request = Task.detached {
                try api.executeLifecycle(plan: plan, cancellation: cancellation)
            }
            defer {
                request.cancel()
                if let self, self.lifecycleID == lifecycleID {
                    self.lifecycleTask = nil
                    self.lifecycleCancellation = nil
                }
            }
            do {
                let result = try await withTaskCancellationHandler(operation: {
                    try await request.value
                }, onCancel: {
                    cancellation.cancel()
                    request.cancel()
                })
                guard !Task.isCancelled, let self, self.lifecycleID == lifecycleID,
                      case .connected = self.connectionState else { return }
                self.lifecycleState = .succeeded(result)
                self.refreshStatus()
            } catch {
                guard !Task.isCancelled, let self, self.lifecycleID == lifecycleID else { return }
                self.lifecycleState = .idle
                self.record(error: Self.failure(from: error))
            }
        }
    }

    public func cancelLifecycle() {
        let action: DesktopLifecycleAction?
        switch lifecycleState {
        case .previewing(let value), .cancelled(let value): action = value
        case .awaitingConfirmation(let plan), .executing(let plan): action = plan.action
        case .succeeded(let result): action = result.action
        case .idle: action = nil
        }
        lifecycleCancellation?.cancel()
        lifecycleTask?.cancel()
        lifecycleTask = nil
        lifecycleID = nil
        lifecycleCancellation = nil
        lifecycleState = action.map(DesktopLifecycleState.cancelled) ?? .idle
    }

    var lifecycleTaskForTesting: Task<Void, Never>? {
        lifecycleTask
    }

    public func refreshStatus() {
        refreshTask?.cancel()
        let refreshID = UUID()
        self.refreshID = refreshID
        let api = self.api
        refreshTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let request = Task.detached {
                try Task.checkCancellation()
                return try api.projectStatus()
            }
            defer {
                request.cancel()
                if let self, self.refreshID == refreshID {
                    self.refreshTask = nil
                    self.refreshID = nil
                }
            }
            do {
                let project = try await withTaskCancellationHandler(operation: {
                    try await request.value
                }, onCancel: {
                    request.cancel()
                })
                guard !Task.isCancelled, let self, self.refreshID == refreshID else { return }
                self.apply(project: project)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.refreshID == refreshID else { return }
                self.record(error: Self.failure(from: error))
            }
        }
    }

    var statusRefreshTaskForTesting: Task<Void, Never>? {
        refreshTask
    }

    var connectionTaskForTesting: Task<Void, Never>? {
        reconnectTask
    }

    public func startEventStream(filter: DesktopEventFilter = .init()) {
        cancelEventStream()
        let eventID = UUID()
        self.eventID = eventID
        isEventStreamRunning = true
        let api = self.api
        eventTask = Task { [weak self] in
            let reader = Task.detached {
                try Self.readEvents(api: api, filter: filter)
            }
            defer {
                reader.cancel()
                if let self, self.eventID == eventID {
                    self.eventTask = nil
                    self.eventID = nil
                    self.isEventStreamRunning = false
                }
            }
            do {
                let values = try await withTaskCancellationHandler(operation: {
                    try await reader.value
                }, onCancel: {
                    reader.cancel()
                })
                guard !Task.isCancelled, let self, self.eventID == eventID else { return }
                self.events = Array(values.suffix(500))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.eventID == eventID else { return }
                self.record(error: Self.failure(from: error))
            }
        }
    }

    public func openLogStream(for serviceID: String, tail: Int = 100) {
        cancelLogStream()
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
        let logID = UUID()
        self.logID = logID
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
            defer {
                reader.cancel()
                if let self, self.logID == logID {
                    self.logTask = nil
                    self.logID = nil
                    self.isLogStreamRunning = false
                }
            }
            do {
                let values = try await withTaskCancellationHandler(operation: {
                    try await reader.value
                }, onCancel: {
                    reader.cancel()
                })
                guard !Task.isCancelled, let self, self.logID == logID else { return }
                self.logChunks = values
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.logID == logID else { return }
                self.record(error: Self.failure(from: error))
            }
        }
    }

    public func cancelEventStream() {
        eventTask?.cancel()
        eventTask = nil
        eventID = nil
        isEventStreamRunning = false
    }

    public func cancelLogStream() {
        logTask?.cancel()
        logTask = nil
        logID = nil
        isLogStreamRunning = false
    }

    var eventStreamTaskForTesting: Task<Void, Never>? {
        eventTask
    }

    var logStreamTaskForTesting: Task<Void, Never>? {
        logTask
    }

    private func connectOnce(connectionID: UUID) async {
        guard !Task.isCancelled, self.connectionID == connectionID else { return }
        connectionState = .connecting
        let api = self.api
        let healthRequest = Task.detached {
            try Task.checkCancellation()
            return try api.daemonHealth()
        }
        defer { healthRequest.cancel() }
        do {
            let health = try await withTaskCancellationHandler(operation: {
                try await healthRequest.value
            }, onCancel: {
                healthRequest.cancel()
            })
            guard !Task.isCancelled, self.connectionID == connectionID else { return }
            daemonHealth = health
            connectionState = .connected
            let statusRequest = Task.detached {
                try Task.checkCancellation()
                return try api.projectStatus()
            }
            defer { statusRequest.cancel() }
            do {
                let project = try await withTaskCancellationHandler(operation: {
                    try await statusRequest.value
                }, onCancel: {
                    statusRequest.cancel()
                })
                guard !Task.isCancelled, self.connectionID == connectionID else { return }
                apply(project: project)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.connectionID == connectionID else { return }
                record(error: Self.failure(from: error))
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.connectionID == connectionID else { return }
            let failure = Self.failure(from: error)
            connectionState = .unavailable(failure)
            lastFailure = failure
        }
    }

    private func apply(project: DesktopProjectStatus) {
        if case .awaitingConfirmation(let plan) = lifecycleState,
           plan.manifestPath != project.manifestPath {
            lifecycleState = .idle
        }
        projects = [project]
        lastFailure = nil
    }

    private func invalidateLifecycleForConnectionChange() {
        lifecycleCancellation?.cancel()
        lifecycleTask?.cancel()
        lifecycleTask = nil
        lifecycleID = nil
        lifecycleCancellation = nil
        lifecycleState = .idle
    }

    private func cancelStatusRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
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

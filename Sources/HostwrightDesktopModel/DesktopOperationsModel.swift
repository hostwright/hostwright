import Combine
import Darwin
import Foundation
import HostwrightCLI
import HostwrightCommandTransport
import HostwrightControlPlane
import HostwrightControlTransport
import HostwrightCore
import HostwrightDaemonCore
import HostwrightManifest
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

private struct DesktopCLIErrorWire: Decodable {
    let kind: String
    let code: String
    let message: String
    let exitCode: Int32
}

public struct DesktopControlAPIClient: Sendable {
    public let transport: any DesktopControlTransport
    private let authorizationScope: @Sendable (
        CLICommand,
        [String]
    ) throws -> CLIControlAuthorizationScope

    public init(
        transport: any DesktopControlTransport,
        authorizationScope: @escaping @Sendable (
            CLICommand,
            [String]
        ) throws -> CLIControlAuthorizationScope = { command, arguments in
            try HostwrightCommandTransportEnvironment.live.authorizationScope(
                command,
                arguments
            )
        }
    ) {
        self.transport = transport
        self.authorizationScope = authorizationScope
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

    public func projectStatus(manifestPath: String? = nil) throws -> DesktopProjectStatus {
        let request: ControlRequestEnvelope
        if let manifestPath {
            let path = try Self.validatedManifestPath(manifestPath)
            do {
                _ = try ManifestValidator.validated(
                    Self.validatedManifestText(for: path)
                )
            } catch let failure as DesktopControlFailure {
                throw failure
            } catch {
                throw DesktopControlFailure(
                    code: "manifest.invalid",
                    message: "The selected manifest is invalid."
                )
            }
            let unscopedRoute = try CLIControlRoute.classify(
                arguments: ["status", path, "--output", "json"]
            )
            let command = try CLICommand.parse(arguments: unscopedRoute.arguments)
            let scope: CLIControlAuthorizationScope
            do {
                scope = try authorizationScope(
                    command,
                    unscopedRoute.arguments
                )
            } catch {
                throw DesktopControlFailure(
                    code: "manifest.authorizationFailed",
                    message: "The selected manifest could not establish an authorized project scope."
                )
            }
            let route = unscopedRoute.withAuthorizationScope(scope)
            request = makeRequest(
                operation: route.operation,
                body: route.requestBody(),
                timeoutMilliseconds: ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
                prefix: "status"
            )
        } else {
            request = makeRequest(
                operation: "status",
                timeoutMilliseconds: ControlPlaneContract.maximumUnaryDeadlineMilliseconds,
                prefix: "status"
            )
        }
        let response = try transport.send(request)
        let checked = try checkedResponse(response, for: request)
        let result: ControlPlaneJSONValue
        if manifestPath != nil {
            let cliResult = try CLIControlResultContract.result(from: checked)
            guard cliResult.exitCode == 0 else {
                throw DesktopControlFailure(
                    code: "status.requestFailed",
                    message: DesktopModelBoundary.redactedMessage(
                        cliResult.standardError,
                        fallback: "The selected manifest status request failed safely."
                    )
                )
            }
            do {
                result = try JSONDecoder().decode(
                    ControlPlaneJSONValue.self,
                    from: Data(cliResult.standardOutput.utf8)
                )
            } catch {
                throw DesktopControlFailure(
                    code: "status.invalidResponse",
                    message: "The daemon returned an invalid selected-manifest status document."
                )
            }
        } else {
            result = try checkedResult(checked)
        }
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
            if let manifestPath, payload.manifest.path != manifestPath {
                throw DesktopControlFailure(
                    code: "status.manifestMismatch",
                    message: "The daemon returned status for a different manifest."
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

    private static func validatedManifestPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096,
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw DesktopControlFailure(
                code: "manifest.invalidPath",
                message: "Choose an absolute local manifest path."
            )
        }
        return path
    }

    private static func validatedManifestText(for path: String) throws -> String {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DesktopControlFailure(
                code: "manifest.unreadable",
                message: "The selected manifest could not be read."
            )
        }
        defer { _ = Darwin.close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_size >= 0 else {
            throw DesktopControlFailure(
                code: "manifest.unsafeFile",
                message: "The selected manifest must be a regular local file."
            )
        }

        let maximumBytes = ManifestParser.maximumUTF8Bytes
        var data = Data()
        let initialCapacity = opened.st_size > Int64(maximumBytes + 1)
            ? maximumBytes + 1
            : Int(opened.st_size)
        data.reserveCapacity(initialCapacity)
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw DesktopControlFailure(
                    code: "manifest.unreadable",
                    message: "The selected manifest could not be read."
                )
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }

        guard data.count <= maximumBytes else {
            throw DesktopControlFailure(
                code: "manifest.tooLarge",
                message: "The selected manifest exceeds the supported size."
            )
        }

        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_mode & S_IFMT == S_IFREG,
              final.st_dev == opened.st_dev,
              final.st_ino == opened.st_ino,
              final.st_size == opened.st_size,
              final.st_size == data.count,
              final.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec else {
            throw DesktopControlFailure(
                code: "manifest.changedDuringRead",
                message: "The selected manifest changed while it was being read."
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DesktopControlFailure(
                code: "manifest.invalidUTF8",
                message: "The selected manifest must be valid UTF-8 text."
            )
        }
        return text
    }

    public func connectSession() throws -> any DesktopControlSession {
        try transport.connectSession()
    }

    public func logStreamRequest(
        manifestPath: String,
        serviceName: String,
        tail: Int
    ) throws -> ControlStreamOpenRequest {
        let path = try Self.validatedManifestPath(manifestPath)
        let arguments = ["logs", serviceName, path, "--tail", String(tail)]
        let command = try CLICommand.parse(arguments: arguments)
        let scope = try authorizationScope(command, arguments)
        guard let target = scope.resourceIdentifier,
              HostwrightResourceUUID.isValid(target) else {
            throw DesktopControlFailure(
                code: "logs.unavailable",
                message: "The selected service has no authorized runtime resource for logs."
            )
        }
        return ControlStreamOpenRequest(
            source: .logs,
            target: target,
            filter: .object([
                "manifestPath": .string(path),
                "serviceName": .string(serviceName),
                "tail": .integer(Int64(tail)),
            ])
        )
    }

    public func lifecyclePreview(
        action: DesktopLifecycleAction,
        manifestPath: String,
        authorizationProjectID: String,
        cancellation: PersistentControlRequestCancellation
    ) throws -> DesktopLifecyclePlanReview {
        let result = try lifecycleCLIResult(
            arguments: [action.rawValue, manifestPath, "--dry-run", "--output", "json"],
            authorizationProjectID: authorizationProjectID,
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
        authorizationProjectID: String,
        cancellation: PersistentControlRequestCancellation
    ) throws -> DesktopLifecycleExecutionResult {
        let result = try lifecycleCLIResult(
            arguments: [
                plan.action.rawValue,
                plan.manifestPath,
                "--confirm-plan", plan.planSHA256,
                "--output", "json",
            ],
            authorizationProjectID: authorizationProjectID,
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
        authorizationProjectID: String,
        cancellation: PersistentControlRequestCancellation,
        prefix: String
    ) throws -> DesktopLifecycleCLIResult {
        let route = try CLIControlRoute.classify(arguments: arguments)
            .withAuthorizationScope(.init(
                projectIdentifier: authorizationProjectID,
                resourceIdentifier: nil
            ))
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
            prefix: prefix,
            mutating: route.mutating
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
            var code = error?.code
            let message: String?
            if error?.code == "cliExitNonZero",
               let result = try? CLIControlResultContract.result(from: response) {
                if let diagnostic = try? JSONDecoder().decode(
                    DesktopCLIErrorWire.self, from: Data(result.standardError.utf8)
                ), diagnostic.kind == "error", diagnostic.exitCode == result.exitCode {
                    code = diagnostic.code
                    message = diagnostic.code == HostwrightErrorCode.confirmationMismatch.rawValue
                        ? "The reviewed plan is out of date. Review a fresh plan before confirming."
                        : diagnostic.message
                } else {
                    message = result.standardError
                }
            } else {
                message = error?.message
            }
            throw DesktopControlFailure(
                code: DesktopModelBoundary.safeCode(
                    code,
                    fallback: "control.requestFailed"
                ),
                message: DesktopModelBoundary.redactedMessage(
                    message,
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
        prefix: String,
        mutating: Bool = false
    ) -> ControlRequestEnvelope {
        let requestID = "desktop-\(prefix)-\(UUID().uuidString.lowercased())"
        return ControlRequestEnvelope(
            requestID: requestID,
            operation: operation,
            timeoutMilliseconds: timeoutMilliseconds,
            idempotencyKey: mutating ? requestID : nil,
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
    @Published public private(set) var selectedManifestPath: String?

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
    private var lifecycleProject: DesktopProjectStatus?
    private var manifestSelectionID = UUID()

    public init(
        endpoint: DesktopControlEndpoint? = nil,
        transport: any DesktopControlTransport,
        authorizationScope: @escaping @Sendable (
            CLICommand, [String]
        ) throws -> CLIControlAuthorizationScope = HostwrightCommandTransportEnvironment.live.authorizationScope,
        reconnectDelaysMilliseconds: [UInt64] = [250, 1_000, 2_000, 5_000]
    ) {
        self.endpoint = endpoint
        self.api = DesktopControlAPIClient(transport: transport, authorizationScope: authorizationScope)
        self.reconnectDelaysMilliseconds = reconnectDelaysMilliseconds.isEmpty
            ? [1_000]
            : reconnectDelaysMilliseconds.map { min($0, 60_000) }
        self.connectionState = .disconnected
    }

    public func selectManifest(at path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path, path.hasPrefix("/") else {
            record(error: DesktopControlFailure(
                code: "manifest.invalidPath",
                message: "Choose an absolute local manifest path."
            ))
            return
        }
        invalidateLifecycleForConnectionChange()
        cancelEventStream()
        cancelLogStream(clearBuffer: true)
        projects = []
        selectedManifestPath = path
        manifestSelectionID = UUID()
        switch connectionState {
        case .connected:
            refreshStatus()
        case .connecting, .reconnecting:
            connect()
        case .disconnected, .unavailable:
            connect()
        }
    }

    public func clearSelectedManifest() {
        invalidateLifecycleForConnectionChange()
        cancelEventStream()
        cancelLogStream(clearBuffer: true)
        projects = []
        selectedManifestPath = nil
        manifestSelectionID = UUID()
        refreshStatus()
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
        cancelEventStream()
        cancelLogStream()
        cancelStatusRefresh()
        projects = []
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
        cancelEventStream()
        cancelLogStream()
        cancelStatusRefresh()
        projects = []
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
        self.lifecycleProject = project
        lifecycleState = .previewing(action)
        lastFailure = nil
        lifecycleTask = Task { [weak self] in
            let request = Task.detached {
                try api.lifecyclePreview(
                    action: action,
                    manifestPath: project.manifestPath,
                    authorizationProjectID: Self.authorizationProjectID(for: project),
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
                guard self.projects.contains(where: { Self.matchesLifecycleProject($0, project) }),
                      plan.projectName == project.name else {
                    self.lifecycleState = .idle
                    self.record(error: Self.staleLifecycleFailure)
                    return
                }
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
              projects.contains(where: { project in
                  project.manifestPath == plan.manifestPath && project.manifestIsValid
                      && lifecycleProject.map { Self.matchesLifecycleProject(project, $0) } == true
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
        guard let project = projects.first(where: {
            $0.manifestPath == plan.manifestPath && $0.manifestIsValid
        }) else {
            lifecycleState = .idle
            record(error: DesktopControlFailure(
                code: "lifecycle.staleConfirmation",
                message: "The lifecycle plan is stale. Review a fresh plan before confirming."
            ))
            return
        }
        let authorizationProjectID = Self.authorizationProjectID(for: project)
        self.lifecycleID = lifecycleID
        self.lifecycleCancellation = cancellation
        lifecycleState = .executing(plan)
        lastFailure = nil
        lifecycleTask = Task { [weak self] in
            let request = Task.detached {
                try api.executeLifecycle(
                    plan: plan,
                    authorizationProjectID: authorizationProjectID,
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
        lifecycleProject = nil
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
        let manifestPath = selectedManifestPath
        let manifestSelectionID = self.manifestSelectionID
        if manifestPath != nil { projects = [] }
        refreshTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let request = Task.detached {
                try Task.checkCancellation()
                return try api.projectStatus(manifestPath: manifestPath)
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
                guard !Task.isCancelled, let self, self.refreshID == refreshID,
                      self.manifestSelectionID == manifestSelectionID else { return }
                self.apply(project: project)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.refreshID == refreshID,
                      self.manifestSelectionID == manifestSelectionID else { return }
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
            service.resourceIdentifier != nil
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

    public func cancelLogStream(clearBuffer: Bool = false) {
        logTask?.cancel()
        logTask = nil
        logID = nil
        isLogStreamRunning = false
        if clearBuffer { logChunks = [] }
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
        let manifestPath = selectedManifestPath
        let manifestSelectionID = self.manifestSelectionID
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
            guard !Task.isCancelled, self.connectionID == connectionID,
                  self.manifestSelectionID == manifestSelectionID else { return }
            daemonHealth = health
            connectionState = .connected
            let statusRequest = Task.detached {
                try Task.checkCancellation()
                return try api.projectStatus(manifestPath: manifestPath)
            }
            defer { statusRequest.cancel() }
            do {
                let project = try await withTaskCancellationHandler(operation: {
                    try await statusRequest.value
                }, onCancel: {
                    statusRequest.cancel()
                })
                guard !Task.isCancelled, self.connectionID == connectionID,
                      self.manifestSelectionID == manifestSelectionID else { return }
                apply(project: project)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.connectionID == connectionID,
                      self.manifestSelectionID == manifestSelectionID else { return }
                record(error: Self.failure(from: error))
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.connectionID == connectionID,
                  self.manifestSelectionID == manifestSelectionID else { return }
            let statusRequest = Task.detached {
                try Task.checkCancellation()
                return try api.projectStatus(manifestPath: manifestPath)
            }
            defer { statusRequest.cancel() }
            do {
                let project = try await withTaskCancellationHandler(operation: {
                    try await statusRequest.value
                }, onCancel: {
                    statusRequest.cancel()
                })
                guard !Task.isCancelled, self.connectionID == connectionID,
                      self.manifestSelectionID == manifestSelectionID else { return }
                apply(project: project)
                connectionState = .connected
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.connectionID == connectionID,
                      self.manifestSelectionID == manifestSelectionID else { return }
                let failure = Self.failure(from: error)
                connectionState = .unavailable(failure)
                lastFailure = failure
            }
        }
    }

    private func apply(project: DesktopProjectStatus) {
        let reviewIsStale: Bool
        if case .awaitingConfirmation = lifecycleState, let lifecycleProject {
            reviewIsStale = !Self.matchesLifecycleProject(project, lifecycleProject)
        } else {
            reviewIsStale = false
        }
        if reviewIsStale { invalidateLifecycleForConnectionChange() }
        if let previous = projects.first,
           previous.manifestPath != project.manifestPath
                || previous.services.count != project.services.count
                || !zip(previous.services, project.services).allSatisfy({ pair in
                    pair.0.id == pair.1.id && pair.0.resourceIdentifier == pair.1.resourceIdentifier
                }) {
            cancelLogStream(clearBuffer: true)
        }
        projects = [project]
        lastFailure = reviewIsStale ? Self.staleLifecycleFailure : nil
    }

    nonisolated private static func matchesLifecycleProject(
        _ current: DesktopProjectStatus,
        _ reviewed: DesktopProjectStatus
    ) -> Bool {
        current.id == reviewed.id && current.manifestPath == reviewed.manifestPath
            && current.manifestIsValid && current.planHash == reviewed.planHash
    }

    nonisolated private static var staleLifecycleFailure: DesktopControlFailure {
        DesktopControlFailure(
            code: "lifecycle.staleConfirmation",
            message: "The lifecycle plan is stale. Review a fresh plan before confirming."
        )
    }

    nonisolated private static func authorizationProjectID(
        for project: DesktopProjectStatus
    ) -> String {
        HostwrightResourceUUID.legacy(kind: "project", identifier: project.id)
    }

    private func invalidateLifecycleForConnectionChange() {
        lifecycleCancellation?.cancel()
        lifecycleTask?.cancel()
        lifecycleTask = nil
        lifecycleID = nil
        lifecycleCancellation = nil
        lifecycleProject = nil
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
        manifestPath: String,
        serviceName: String,
        tail: Int
    ) throws -> [DesktopLogChunk] {
        let request = try api.logStreamRequest(
            manifestPath: manifestPath,
            serviceName: serviceName,
            tail: tail
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

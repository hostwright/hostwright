import XCTest
@testable import HostwrightDesktopModel
import HostwrightControlPlane
import HostwrightControlTransport

@MainActor
final class DesktopOperationsModelTests: XCTestCase {
    func testEndpointDiscoveryUsesTheSecureLocalPathLayout() throws {
        let endpoint = try DesktopControlEndpoint.discover(
            homeDirectory: "/Users/tester",
            environment: [:]
        )

        XCTAssertEqual(
            endpoint.socketPath,
            "/Users/tester/Library/Application Support/Hostwright/run/control-v2.sock"
        )
        XCTAssertEqual(
            endpoint.stateDatabasePath,
            "/Users/tester/Library/Application Support/Hostwright/state/state.sqlite"
        )
    }

    func testEventFilterBuildsTheProtocolFilterAndRejectsUnboundedValues() throws {
        let filter = DesktopEventFilter(
            projectID: "project-demo",
            type: "status.observed",
            serviceName: "web",
            severity: "warning",
            maximumEvents: 12,
            waitForFirst: true
        )
        let request = try filter.controlStreamRequest()

        XCTAssertEqual(request.source, .events)
        XCTAssertEqual(
            request.filter,
            .object([
                "projectID": .string("project-demo"),
                "type": .string("status.observed"),
                "serviceName": .string("web"),
                "severity": .string("warning"),
                "endAfterSnapshot": .bool(true),
                "maximumEvents": .integer(12),
                "waitForFirst": .bool(true),
            ])
        )

        XCTAssertThrowsError(
            try DesktopEventFilter(maximumEvents: 2_000).controlStreamRequest()
        ) { error in
            XCTAssertEqual(
                (error as? DesktopControlFailure)?.code,
                "events.invalidFilter"
            )
        }
    }

    func testAPIMapsDaemonHealthAndProjectServicesFromRealResponseShapes() throws {
        let transport = ScriptedTransport { request in
            if request.operation == "daemon" {
                return Self.completed(
                    request: request,
                    result: .object([
                        "exitCode": .integer(0),
                        "resultSchemaVersion": .integer(1),
                        "standardError": .string(""),
                        "standardOutput": .string(Self.daemonHealthJSON),
                    ])
                )
            }
            return Self.completed(request: request, result: Self.statusJSON)
        }
        let api = DesktopControlAPIClient(transport: transport)

        let health = try api.daemonHealth()
        let project = try api.projectStatus()

        XCTAssertEqual(health.readiness, "running")
        XCTAssertEqual(health.processID, 913)
        XCTAssertEqual(project.id, "project-demo")
        XCTAssertEqual(project.services.first?.id, "web")
        XCTAssertEqual(project.services.first?.availability, .healthy)
        XCTAssertEqual(transport.requests.map(\.operation), ["daemon", "status"])
    }

    func testControlErrorsStayRedactedAtTheDesktopBoundary() throws {
        let transport = ScriptedTransport { request in
            ControlResponseEnvelope(
                requestID: request.requestID,
                status: .error,
                reasonCode: .internalError,
                error: SanitizedError(
                    code: "runtimeLogsUnavailable",
                    message: "token=secret-value password=another-secret"
                )
            )
        }

        XCTAssertThrowsError(
            try DesktopControlAPIClient(transport: transport).projectStatus()
        ) { error in
            let failure = error as? DesktopControlFailure
            XCTAssertEqual(failure?.code, "runtimeLogsUnavailable")
            XCTAssertFalse(failure?.message.contains("secret-value") == true)
            XCTAssertFalse(failure?.message.contains("another-secret") == true)
        }
    }

    func testModelConnectsThroughTheClientAndKeepsStatusFailureVisible() async throws {
        let transport = ScriptedTransport { request in
            if request.operation == "daemon" {
                return Self.completed(
                    request: request,
                    result: .object([
                        "exitCode": .integer(0),
                        "resultSchemaVersion": .integer(1),
                        "standardError": .string(""),
                        "standardOutput": .string(Self.daemonHealthJSON),
                    ])
                )
            }
            return Self.completed(request: request, result: Self.statusJSON)
        }
        let model = DesktopOperationsModel(transport: transport)

        model.connect()
        for _ in 0..<20 {
            if model.connectionState == .connected && !model.projects.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertEqual(model.projects.first?.name, "demo")
        XCTAssertNil(model.lastFailure)
    }

    func testEventAndLogStreamsOpenWithCreditsAcknowledgePayloadsAndFinish() async throws {
        let session = ScriptedStreamSession(
            eventFrames: [
                StreamFrame(
                    streamID: "pending",
                    sequence: 1,
                    kind: .open
                ),
                StreamFrame(
                    streamID: "pending",
                    sequence: 2,
                    cursor: "event-cursor",
                    kind: .data,
                    payload: .object([
                        "eventReference": .string("event-ref"),
                        "id": .string("event-id"),
                        "message": .string("Observed web."),
                        "operationReferences": .array([]),
                        "payloadJSONRedacted": .string("{}"),
                        "position": .integer(7),
                        "projectID": .string("project-demo"),
                        "runtimeAdapter": .string("apple-container-cli"),
                        "serviceName": .string("web"),
                        "severity": .string("info"),
                        "source": .string("hostwright"),
                        "timestamp": .string("2026-08-09T19:00:00Z"),
                        "type": .string("status.observed"),
                    ])
                ),
                StreamFrame(
                    streamID: "pending",
                    sequence: 3,
                    kind: .end
                ),
            ],
            logFrames: [
                StreamFrame(
                    streamID: "pending",
                    sequence: 1,
                    kind: .open
                ),
                StreamFrame(
                    streamID: "pending",
                    sequence: 2,
                    cursor: "log-cursor",
                    kind: .data,
                    payload: .object([
                        "encoding": .string("base64"),
                        "ordinal": .integer(0),
                        "payload": .string(Data("hello\n".utf8).base64EncodedString()),
                    ])
                ),
                StreamFrame(
                    streamID: "pending",
                    sequence: 3,
                    kind: .end
                ),
            ]
        )
        let transport = ScriptedTransport(
            responseProvider: { request in
                if request.operation == "daemon" {
                    return Self.completed(
                        request: request,
                        result: .object([
                            "exitCode": .integer(0),
                            "resultSchemaVersion": .integer(1),
                            "standardError": .string(""),
                            "standardOutput": .string(Self.daemonHealthJSON),
                        ])
                    )
                }
                return Self.completed(request: request, result: Self.statusJSON)
            },
            session: session
        )
        let model = DesktopOperationsModel(transport: transport)
        model.connect()
        for _ in 0..<20 {
            if !model.projects.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        model.startEventStream()
        for _ in 0..<50 {
            if !model.isEventStreamRunning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.openLogStream(for: "web")
        for _ in 0..<50 {
            if !model.isLogStreamRunning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.events.first?.message, "Observed web.")
        XCTAssertEqual(model.logChunks.first?.text, "hello\n")
        XCTAssertEqual(session.openedSources, [.events, .logs])
        XCTAssertEqual(session.acknowledgements.map(\.credit), [1, 1])
        XCTAssertEqual(session.acknowledgements.map(\.cursor), ["event-cursor", "log-cursor"])
        XCTAssertEqual(session.openedInitialCredits, [32, 16])
    }

    func testCancellingAnActiveEventStreamCancelsTheControlStream() async throws {
        let session = ScriptedStreamSession(
            eventFrames: [],
            logFrames: [],
            blocksEvents: true
        )
        let model = DesktopOperationsModel(
            transport: ScriptedTransport(
                responseProvider: { request in
                    Self.completed(request: request, result: Self.statusJSON)
                },
                session: session
            )
        )

        model.startEventStream()
        for _ in 0..<20 {
            if model.isEventStreamRunning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.cancelStreams()
        for _ in 0..<50 {
            if session.cancelCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertFalse(model.isEventStreamRunning)
    }

    func testReconnectExposesBackoffAndDisconnectCancelsTheRetryLoop() async throws {
        let model = DesktopOperationsModel(
            transport: ScriptedTransport { _ in
                throw DesktopControlFailure(
                    code: "transport.connectionFailed",
                    message: "The local control connection is unavailable."
                )
            },
            reconnectDelaysMilliseconds: [50, 50, 50]
        )

        model.reconnect()
        var sawBackoff = false
        for _ in 0..<40 {
            if case .reconnecting = model.connectionState {
                sawBackoff = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        model.disconnect()

        XCTAssertTrue(sawBackoff)
        XCTAssertEqual(model.connectionState, .disconnected)
    }

    func testActionAvailabilityTracksConnectionStreamsAndObservedLogResources() async throws {
        let model = DesktopOperationsModel(
            transport: ScriptedTransport { request in
                if request.operation == "daemon" {
                    return Self.completed(
                        request: request,
                        result: .object([
                            "exitCode": .integer(0),
                            "resultSchemaVersion": .integer(1),
                            "standardError": .string(""),
                            "standardOutput": .string(Self.daemonHealthJSON),
                        ])
                    )
                }
                return Self.completed(request: request, result: Self.statusJSON)
            }
        )

        XCTAssertEqual(
            model.actionAvailability(for: DesktopAccessibilityIdentifier.statusRefresh).reason,
            .disconnected
        )
        XCTAssertEqual(
            model.actionAvailability(for: DesktopAccessibilityIdentifier.eventsCancel).reason,
            .streamNotRunning
        )

        model.connect()
        for _ in 0..<20 {
            if model.connectionState == .connected && !model.projects.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(
            model.actionAvailability(for: DesktopAccessibilityIdentifier.statusRefresh).state,
            .available
        )
        XCTAssertEqual(
            model.actionAvailability(for: DesktopAccessibilityIdentifier.eventsRefresh).state,
            .available
        )
        XCTAssertEqual(
            model.actionAvailability(for: DesktopAccessibilityIdentifier.selectedLogsOpen).reason,
            .requiresService
        )
        XCTAssertEqual(
            model.actionAvailability(
                for: DesktopAccessibilityIdentifier.selectedLogsOpen,
                context: DesktopActionAvailabilityContext(serviceID: "missing")
            ).reason,
            .requiresService
        )
        XCTAssertEqual(
            model.actionAvailability(
                for: DesktopAccessibilityIdentifier.selectedLogsOpen,
                context: DesktopActionAvailabilityContext(serviceID: "web")
            ).state,
            .available
        )

        model.disconnect()
        XCTAssertEqual(
            model.actionAvailability(for: DesktopAccessibilityIdentifier.statusRefresh).reason,
            .disconnected
        )

        let unavailable = DesktopOperationsModel.live(
            homeDirectory: "/Users/tester",
            environment: ["HOSTWRIGHT_APPLICATION_SUPPORT_DIR": "relative"]
        )
        XCTAssertEqual(
            unavailable.actionAvailability(for: DesktopAccessibilityIdentifier.statusRefresh).reason,
            .controlEndpointUnavailable
        )
    }

    nonisolated private static let daemonHealthJSON = """
    {
      "schemaVersion": 1,
      "operation": "status",
      "changed": false,
      "reasonCode": "daemon.started",
      "status": {
        "schemaVersion": 1,
        "label": "dev.hostwright",
        "domain": "gui/501",
        "readiness": "running",
        "propertyListPath": "/private/var/hostwright.plist",
        "daemonExecutablePath": null,
        "configPath": "/Users/tester/project.yml",
        "generation": 3,
        "installationID": "installation-1",
        "processID": 913,
        "pendingOperation": null,
        "reasonCode": "daemon.started"
      }
    }
    """

    nonisolated private static let statusJSON = ControlPlaneJSONValue.object([
        "manifest": .object([
            "exists": .bool(true),
            "path": .string("/Users/tester/project.yml"),
            "valid": .bool(true),
        ]),
        "planHash": .string("sha256:plan"),
        "project": .string("demo"),
        "services": .array([
            .object([
                "desiredImage": .string("example/web:1"),
                "name": .string("web"),
                "observed": .object([
                    "health": .string("healthy"),
                    "image": .string("example/web@sha256:image"),
                    "lifecycle": .string("running"),
                    "resourceIdentifier": .string("resource-web"),
                ]),
            ])
        ]),
    ])

    nonisolated private static func completed(
        request: ControlRequestEnvelope,
        result: ControlPlaneJSONValue
    ) -> ControlResponseEnvelope {
        ControlResponseEnvelope(
            requestID: request.requestID,
            status: .completed,
            reasonCode: .completed,
            result: result
        )
    }
}

private final class ScriptedTransport: DesktopControlTransport, @unchecked Sendable {
    typealias ResponseProvider = @Sendable (ControlRequestEnvelope) throws -> ControlResponseEnvelope

    private let lock = NSLock()
    private let responseProvider: ResponseProvider
    private let session: (any DesktopControlSession)?
    private var recordedRequests: [ControlRequestEnvelope] = []

    init(
        responseProvider: @escaping ResponseProvider,
        session: (any DesktopControlSession)? = nil
    ) {
        self.responseProvider = responseProvider
        self.session = session
    }

    var requests: [ControlRequestEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func send(_ request: ControlRequestEnvelope) throws -> ControlResponseEnvelope {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
        return try responseProvider(request)
    }

    func connectSession() throws -> any DesktopControlSession {
        if let session {
            return session
        }
        throw DesktopControlFailure(
            code: "test.noSession",
            message: "The test transport has no stream session."
        )
    }
}

private final class ScriptedStreamSession: DesktopControlSession, @unchecked Sendable {
    struct Acknowledgement {
        let credit: Int
        let cursor: String?
    }

    private let lock = NSLock()
    private var eventFrames: [StreamFrame]
    private var logFrames: [StreamFrame]
    private var activeFrames: [StreamFrame] = []
    private let blocksEvents: Bool
    private var activeSource: ControlStreamSource?
    private(set) var openedSources: [ControlStreamSource] = []
    private(set) var openedInitialCredits: [Int] = []
    private(set) var acknowledgements: [Acknowledgement] = []
    private(set) var cancelCount = 0

    init(
        eventFrames: [StreamFrame],
        logFrames: [StreamFrame],
        blocksEvents: Bool = false
    ) {
        self.eventFrames = eventFrames
        self.logFrames = logFrames
        self.blocksEvents = blocksEvents
    }

    func openStream(
        streamID: String,
        request: ControlStreamOpenRequest,
        cursor: String?,
        initialCredit: Int
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        openedSources.append(request.source)
        openedInitialCredits.append(initialCredit)
        activeSource = request.source
        activeFrames = request.source == .events ? eventFrames : logFrames
            .map { frame in
                StreamFrame(
                    streamID: streamID,
                    sequence: frame.sequence,
                    cursor: frame.cursor,
                    kind: frame.kind,
                    credit: frame.credit,
                    payload: frame.payload,
                    error: frame.error
                )
            }
    }

    func nextFrame(streamID: String, timeoutMilliseconds: Int) throws -> StreamFrame {
        lock.lock()
        defer { lock.unlock() }
        if blocksEvents && activeSource == .events {
            throw PersistentControlClientError.deadlineExceeded
        }
        guard !activeFrames.isEmpty else {
            throw DesktopControlFailure(
                code: "test.noFrame",
                message: "The scripted stream ended without a terminal frame."
            )
        }
        return activeFrames.removeFirst()
    }

    func acknowledge(streamID: String, credit: Int, cursor: String?) throws {
        lock.lock()
        acknowledgements.append(Acknowledgement(credit: credit, cursor: cursor))
        lock.unlock()
    }

    func cancel(streamID: String) throws {
        lock.lock()
        cancelCount += 1
        lock.unlock()
    }

    func close() {}
}

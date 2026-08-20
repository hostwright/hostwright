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
        model.cancelEventStream()
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

    func testDisconnectFencesLateDaemonHealthSuccessAndFailure() async {
        for outcome in LateConnectionOutcome.allCases {
            await assertDisconnectFencesLateConnectionResult(
                at: .daemonHealth,
                outcome: outcome
            )
        }
    }

    func testDisconnectFencesLateProjectStatusSuccessAndFailure() async {
        for outcome in LateConnectionOutcome.allCases {
            await assertDisconnectFencesLateConnectionResult(
                at: .projectStatus,
                outcome: outcome
            )
        }
    }

    func testReplacementConnectFencesLateDaemonHealthSuccessAndFailure() async {
        for outcome in LateConnectionOutcome.allCases {
            await assertReplacementConnectFencesLateConnectionResult(
                at: .daemonHealth,
                outcome: outcome
            )
        }
    }

    func testReplacementConnectFencesLateProjectStatusSuccessAndFailure() async {
        for outcome in LateConnectionOutcome.allCases {
            await assertReplacementConnectFencesLateConnectionResult(
                at: .projectStatus,
                outcome: outcome
            )
        }
    }

    func testSupersededConnectCannotClearReplacementTaskOwnership() async {
        let healthGate = FirstConnectionStageGate(stage: .daemonHealth)
        let statusGate = FirstConnectionStageGate(stage: .projectStatus)
        let model = makeConnectionRaceModel(
            gates: [healthGate, statusGate],
            lateOutcome: .success
        )
        defer {
            healthGate.release()
            statusGate.release()
        }

        model.connect()
        guard let supersededTask = model.connectionTaskForTesting else {
            return XCTFail("The model did not retain the superseded connection task.")
        }
        await fulfillment(of: [healthGate.started], timeout: 1)

        model.connect()
        guard let replacementTask = model.connectionTaskForTesting else {
            return XCTFail("The model did not retain the replacement connection task.")
        }
        await fulfillment(of: [statusGate.started], timeout: 1)

        healthGate.release()
        await supersededTask.value

        XCTAssertNotNil(model.connectionTaskForTesting)
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertTrue(model.projects.isEmpty)

        statusGate.release()
        await replacementTask.value

        XCTAssertNil(model.connectionTaskForTesting)
        XCTAssertEqual(model.projects.first?.name, "demo")
        XCTAssertNil(model.lastFailure)
    }

    func testDisconnectPreventsLateStatusRefreshFromApplyingAProject() async throws {
        let gate = BlockingResponseGate()
        defer { gate.release() }
        let model = DesktopOperationsModel(
            transport: ScriptedTransport { request in
                gate.block()
                return Self.completed(request: request, result: Self.statusJSON)
            }
        )

        model.refreshStatus()
        guard let refreshTask = model.statusRefreshTaskForTesting else {
            return XCTFail("The model did not retain the status refresh task.")
        }
        await fulfillment(of: [gate.started], timeout: 1)

        model.disconnect()
        gate.release()
        await refreshTask.value

        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertNil(model.lastFailure)
    }

    func testDisconnectPreventsLateStatusRefreshFromApplyingAnError() async throws {
        let gate = BlockingResponseGate()
        defer { gate.release() }
        let model = DesktopOperationsModel(
            transport: ScriptedTransport { _ in
                gate.block()
                throw DesktopControlFailure(
                    code: "transport.connectionFailed",
                    message: "The local control connection is unavailable."
                )
            }
        )

        model.refreshStatus()
        guard let refreshTask = model.statusRefreshTaskForTesting else {
            return XCTFail("The model did not retain the status refresh task.")
        }
        await fulfillment(of: [gate.started], timeout: 1)

        model.disconnect()
        gate.release()
        await refreshTask.value

        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertNil(model.lastFailure)
    }

    func testNewStatusRefreshPreventsSupersededSuccessFromOverwritingProject() async throws {
        let gate = FirstResponseGate()
        let model = DesktopOperationsModel(
            transport: ScriptedTransport { request in
                if gate.enter() {
                    return Self.completed(
                        request: request,
                        result: Self.statusJSON(projectName: "stale")
                    )
                }
                return Self.completed(request: request, result: Self.statusJSON)
            }
        )
        defer { gate.release() }

        model.refreshStatus()
        guard let supersededTask = model.statusRefreshTaskForTesting else {
            return XCTFail("The model did not retain the first status refresh task.")
        }
        await fulfillment(of: [gate.started], timeout: 1)

        model.refreshStatus()
        guard let currentTask = model.statusRefreshTaskForTesting else {
            return XCTFail("The model did not retain the replacement status refresh task.")
        }
        await currentTask.value
        XCTAssertEqual(model.projects.first?.name, "demo")

        gate.release()
        await supersededTask.value

        XCTAssertEqual(model.projects.first?.name, "demo")
        XCTAssertNil(model.lastFailure)
    }

    func testNewStatusRefreshPreventsSupersededErrorFromOverwritingState() async throws {
        let gate = FirstResponseGate()
        let model = DesktopOperationsModel(
            transport: ScriptedTransport { request in
                if gate.enter() {
                    throw DesktopControlFailure(
                        code: "transport.connectionFailed",
                        message: "The stale control connection is unavailable."
                    )
                }
                return Self.completed(request: request, result: Self.statusJSON)
            }
        )
        defer { gate.release() }

        model.refreshStatus()
        guard let supersededTask = model.statusRefreshTaskForTesting else {
            return XCTFail("The model did not retain the first status refresh task.")
        }
        await fulfillment(of: [gate.started], timeout: 1)

        model.refreshStatus()
        guard let currentTask = model.statusRefreshTaskForTesting else {
            return XCTFail("The model did not retain the replacement status refresh task.")
        }
        await currentTask.value
        XCTAssertEqual(model.projects.first?.name, "demo")

        gate.release()
        await supersededTask.value

        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertEqual(model.projects.first?.name, "demo")
        XCTAssertNil(model.lastFailure)
    }

    func testConnectAndReconnectFenceLatePreexistingRefreshSuccess() async {
        for invocation in ConnectionInvocation.allCases {
            await assertConnectionFencesLatePreexistingRefresh(
                invocation: invocation,
                outcome: .success
            )
        }
    }

    func testConnectAndReconnectFenceLatePreexistingRefreshError() async {
        for invocation in ConnectionInvocation.allCases {
            await assertConnectionFencesLatePreexistingRefresh(
                invocation: invocation,
                outcome: .failure
            )
        }
    }

    func testEventCancellationLeavesConcurrentLogStreamRunning() async {
        await assertStreamCancellationIsolation(cancelledSource: .events)
    }

    func testLogCancellationLeavesConcurrentEventStreamRunning() async {
        await assertStreamCancellationIsolation(cancelledSource: .logs)
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

    nonisolated private static let statusJSON = statusJSON(projectName: "demo")

    nonisolated private static func statusJSON(projectName: String) -> ControlPlaneJSONValue {
        .object([
            "manifest": .object([
                "exists": .bool(true),
                "path": .string("/Users/tester/project.yml"),
                "valid": .bool(true),
            ]),
            "planHash": .string("sha256:plan"),
            "project": .string(projectName),
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
    }

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

    private func assertDisconnectFencesLateConnectionResult(
        at stage: ConnectionStage,
        outcome: LateConnectionOutcome
    ) async {
        let gate = FirstConnectionStageGate(stage: stage)
        let model = makeConnectionRaceModel(gates: [gate], lateOutcome: outcome)
        defer { gate.release() }

        model.connect()
        guard let connectionTask = model.connectionTaskForTesting else {
            return XCTFail("The model did not retain the connection task.")
        }
        await fulfillment(of: [gate.started], timeout: 1)

        model.disconnect()
        gate.release()
        await connectionTask.value

        XCTAssertEqual(
            model.connectionState,
            .disconnected,
            "A late \(stage) \(outcome) changed disconnected state."
        )
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertNil(model.lastFailure)
        if stage == .daemonHealth {
            XCTAssertNil(model.daemonHealth)
        } else {
            XCTAssertEqual(model.daemonHealth?.generation, 3)
        }
    }

    private func assertReplacementConnectFencesLateConnectionResult(
        at stage: ConnectionStage,
        outcome: LateConnectionOutcome
    ) async {
        let gate = FirstConnectionStageGate(stage: stage)
        let model = makeConnectionRaceModel(gates: [gate], lateOutcome: outcome)
        defer { gate.release() }

        model.connect()
        guard let supersededTask = model.connectionTaskForTesting else {
            return XCTFail("The model did not retain the superseded connection task.")
        }
        await fulfillment(of: [gate.started], timeout: 1)

        model.connect()
        guard let replacementTask = model.connectionTaskForTesting else {
            return XCTFail("The model did not retain the replacement connection task.")
        }
        await replacementTask.value

        gate.release()
        await supersededTask.value

        XCTAssertEqual(
            model.connectionState,
            .connected,
            "A late \(stage) \(outcome) changed replacement connection state."
        )
        XCTAssertEqual(model.daemonHealth?.generation, 3)
        XCTAssertEqual(model.projects.first?.name, "demo")
        XCTAssertNil(model.lastFailure)
        XCTAssertNil(model.connectionTaskForTesting)
    }

    private func makeConnectionRaceModel(
        gates: [FirstConnectionStageGate],
        lateOutcome: LateConnectionOutcome
    ) -> DesktopOperationsModel {
        DesktopOperationsModel(
            transport: ScriptedTransport { request in
                let isLateResponse = gates.contains {
                    $0.blockIfFirstMatching(request.operation)
                }
                if isLateResponse {
                    if lateOutcome == .failure {
                        throw DesktopControlFailure(
                            code: "transport.connectionFailed",
                            message: "The stale control connection is unavailable."
                        )
                    }
                    return Self.connectionResponse(
                        request: request,
                        generation: 1,
                        projectName: "stale"
                    )
                }
                return Self.connectionResponse(
                    request: request,
                    generation: 3,
                    projectName: "demo"
                )
            }
        )
    }

    private func assertConnectionFencesLatePreexistingRefresh(
        invocation: ConnectionInvocation,
        outcome: LateConnectionOutcome
    ) async {
        let gate = RefreshReconnectRaceGate()
        defer { gate.releaseAll() }
        let model = DesktopOperationsModel(
            transport: ScriptedTransport { request in
                guard request.operation == "status" else {
                    return Self.connectionResponse(
                        request: request,
                        generation: 3,
                        projectName: "fresh"
                    )
                }
                let ordinal = gate.enterStatusRequest()
                if ordinal == 1 {
                    if outcome == .failure {
                        throw DesktopControlFailure(
                            code: "transport.connectionFailed",
                            message: "The stale control connection is unavailable."
                        )
                    }
                    return Self.completed(
                        request: request,
                        result: Self.statusJSON(projectName: "stale")
                    )
                }
                return Self.completed(
                    request: request,
                    result: Self.statusJSON(projectName: "fresh")
                )
            },
            reconnectDelaysMilliseconds: [1]
        )

        model.refreshStatus()
        guard let staleRefreshTask = model.statusRefreshTaskForTesting else {
            return XCTFail("The model did not retain the pre-connection refresh task.")
        }
        await fulfillment(of: [gate.staleRefreshStarted], timeout: 1)

        invocation.start(model)
        guard let connectionTask = model.connectionTaskForTesting else {
            return XCTFail("The model did not retain the replacement connection task.")
        }
        await fulfillment(of: [gate.connectionStatusStarted], timeout: 1)

        gate.releaseStaleRefresh()
        await staleRefreshTask.value

        XCTAssertNotNil(
            model.connectionTaskForTesting,
            "A stale refresh cleared \(invocation) ownership."
        )
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertNil(model.lastFailure)

        gate.releaseConnectionStatus()
        await connectionTask.value

        XCTAssertNil(model.connectionTaskForTesting)
        XCTAssertNil(model.statusRefreshTaskForTesting)
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertEqual(model.projects.first?.name, "fresh")
        XCTAssertNil(model.lastFailure)
    }

    private func assertStreamCancellationIsolation(
        cancelledSource: ControlStreamSource
    ) async {
        let streams = ConcurrentStreamHarness()
        defer { streams.releaseAll() }
        let model = DesktopOperationsModel(
            transport: ScriptedTransport(
                responseProvider: { request in
                    Self.connectionResponse(
                        request: request,
                        generation: 3,
                        projectName: "demo"
                    )
                },
                sessionProvider: { streams.makeSession() }
            )
        )
        model.connect()
        guard let connectionTask = model.connectionTaskForTesting else {
            return XCTFail("The model did not retain the setup connection task.")
        }
        await connectionTask.value

        model.startEventStream()
        model.openLogStream(for: "web")
        guard let eventTask = model.eventStreamTaskForTesting,
            let logTask = model.logStreamTaskForTesting
        else {
            return XCTFail("The model did not retain both concurrent stream tasks.")
        }
        await fulfillment(
            of: [streams.eventStarted, streams.logStarted],
            timeout: 1
        )

        if cancelledSource == .events {
            model.cancelEventStream()
            XCTAssertFalse(model.isEventStreamRunning)
            XCTAssertTrue(model.isLogStreamRunning)
            XCTAssertNotNil(model.logStreamTaskForTesting)
            streams.release(.events)
            await eventTask.value
            XCTAssertEqual(streams.cancelledSources, [.events])
            XCTAssertTrue(model.isLogStreamRunning)

            model.cancelLogStream()
            streams.release(.logs)
        } else {
            model.cancelLogStream()
            XCTAssertFalse(model.isLogStreamRunning)
            XCTAssertTrue(model.isEventStreamRunning)
            XCTAssertNotNil(model.eventStreamTaskForTesting)
            streams.release(.logs)
            await logTask.value
            XCTAssertEqual(streams.cancelledSources, [.logs])
            XCTAssertTrue(model.isEventStreamRunning)

            model.cancelEventStream()
            streams.release(.events)
        }

        await eventTask.value
        await logTask.value
        XCTAssertFalse(model.isEventStreamRunning)
        XCTAssertFalse(model.isLogStreamRunning)
        XCTAssertEqual(Set(streams.cancelledSources), Set([.events, .logs]))
    }

    nonisolated private static func connectionResponse(
        request: ControlRequestEnvelope,
        generation: Int,
        projectName: String
    ) -> ControlResponseEnvelope {
        if request.operation == "daemon" {
            return completed(
                request: request,
                result: .object([
                    "exitCode": .integer(0),
                    "resultSchemaVersion": .integer(1),
                    "standardError": .string(""),
                    "standardOutput": .string(
                        daemonHealthJSON.replacingOccurrences(
                            of: "\"generation\": 3",
                            with: "\"generation\": \(generation)"
                        )
                    ),
                ])
            )
        }
        return completed(request: request, result: statusJSON(projectName: projectName))
    }
}

private enum ConnectionStage: String, Sendable {
    case daemonHealth = "daemon"
    case projectStatus = "status"
}

private enum LateConnectionOutcome: String, CaseIterable, Sendable {
    case success
    case failure
}

private enum ConnectionInvocation: String, CaseIterable, Sendable {
    case connect
    case reconnect

    @MainActor
    func start(_ model: DesktopOperationsModel) {
        switch self {
        case .connect:
            model.connect()
        case .reconnect:
            model.reconnect()
        }
    }
}

private final class ScriptedTransport: DesktopControlTransport, @unchecked Sendable {
    typealias ResponseProvider = @Sendable (ControlRequestEnvelope) throws -> ControlResponseEnvelope

    private let lock = NSLock()
    private let responseProvider: ResponseProvider
    private let session: (any DesktopControlSession)?
    private let sessionProvider: (@Sendable () throws -> any DesktopControlSession)?
    private var recordedRequests: [ControlRequestEnvelope] = []

    init(
        responseProvider: @escaping ResponseProvider,
        session: (any DesktopControlSession)? = nil,
        sessionProvider: (@Sendable () throws -> any DesktopControlSession)? = nil
    ) {
        self.responseProvider = responseProvider
        self.session = session
        self.sessionProvider = sessionProvider
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
        if let sessionProvider {
            return try sessionProvider()
        }
        if let session {
            return session
        }
        throw DesktopControlFailure(
            code: "test.noSession",
            message: "The test transport has no stream session."
        )
    }
}

private final class RefreshReconnectRaceGate: @unchecked Sendable {
    let staleRefreshStarted = XCTestExpectation(
        description: "pre-connection refresh entered transport"
    )
    let connectionStatusStarted = XCTestExpectation(
        description: "replacement connection status entered transport"
    )

    private let lock = NSLock()
    private let staleRefreshSemaphore = DispatchSemaphore(value: 0)
    private let connectionStatusSemaphore = DispatchSemaphore(value: 0)
    private var statusRequestCount = 0
    private var releasedStaleRefresh = false
    private var releasedConnectionStatus = false

    func enterStatusRequest() -> Int {
        lock.lock()
        statusRequestCount += 1
        let ordinal = statusRequestCount
        lock.unlock()
        if ordinal == 1 {
            staleRefreshStarted.fulfill()
            staleRefreshSemaphore.wait()
        } else if ordinal == 2 {
            connectionStatusStarted.fulfill()
            connectionStatusSemaphore.wait()
        }
        return ordinal
    }

    func releaseStaleRefresh() {
        lock.lock()
        guard !releasedStaleRefresh else {
            lock.unlock()
            return
        }
        releasedStaleRefresh = true
        lock.unlock()
        staleRefreshSemaphore.signal()
    }

    func releaseConnectionStatus() {
        lock.lock()
        guard !releasedConnectionStatus else {
            lock.unlock()
            return
        }
        releasedConnectionStatus = true
        lock.unlock()
        connectionStatusSemaphore.signal()
    }

    func releaseAll() {
        releaseStaleRefresh()
        releaseConnectionStatus()
    }
}

private final class ConcurrentStreamHarness: @unchecked Sendable {
    let eventStarted = XCTestExpectation(description: "event stream entered frame read")
    let logStarted = XCTestExpectation(description: "log stream entered frame read")

    private let lock = NSLock()
    private let eventSemaphore = DispatchSemaphore(value: 0)
    private let logSemaphore = DispatchSemaphore(value: 0)
    private var releasedSources: Set<ControlStreamSource> = []
    private var recordedCancellations: [ControlStreamSource] = []

    var cancelledSources: [ControlStreamSource] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCancellations
    }

    func makeSession() -> any DesktopControlSession {
        ConcurrentBlockingStreamSession(harness: self)
    }

    func block(_ source: ControlStreamSource) throws -> StreamFrame {
        switch source {
        case .events:
            eventStarted.fulfill()
            eventSemaphore.wait()
        case .logs:
            logStarted.fulfill()
            logSemaphore.wait()
        default:
            XCTFail("The desktop model opened an unexpected \(source) stream.")
        }
        throw PersistentControlClientError.deadlineExceeded
    }

    func recordCancellation(_ source: ControlStreamSource) {
        lock.lock()
        recordedCancellations.append(source)
        lock.unlock()
    }

    func release(_ source: ControlStreamSource) {
        lock.lock()
        guard releasedSources.insert(source).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()
        switch source {
        case .events:
            eventSemaphore.signal()
        case .logs:
            logSemaphore.signal()
        default:
            break
        }
    }

    func releaseAll() {
        release(.events)
        release(.logs)
    }
}

private final class ConcurrentBlockingStreamSession: DesktopControlSession, @unchecked Sendable {
    private let harness: ConcurrentStreamHarness
    private let lock = NSLock()
    private var source: ControlStreamSource?

    init(harness: ConcurrentStreamHarness) {
        self.harness = harness
    }

    func openStream(
        streamID: String,
        request: ControlStreamOpenRequest,
        cursor: String?,
        initialCredit: Int
    ) throws {
        lock.lock()
        source = request.source
        lock.unlock()
    }

    func nextFrame(streamID: String, timeoutMilliseconds: Int) throws -> StreamFrame {
        lock.lock()
        let source = source
        lock.unlock()
        guard let source else {
            throw DesktopControlFailure(
                code: "test.streamNotOpened",
                message: "The scripted stream was read before it was opened."
            )
        }
        return try harness.block(source)
    }

    func acknowledge(streamID: String, credit: Int, cursor: String?) throws {}

    func cancel(streamID: String) throws {
        lock.lock()
        let source = source
        lock.unlock()
        if let source {
            harness.recordCancellation(source)
        }
    }

    func close() {}
}

private final class BlockingResponseGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "status refresh entered transport")

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var isReleased = false

    func block() {
        started.fulfill()
        semaphore.wait()
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        semaphore.signal()
    }
}

private final class FirstResponseGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "first status refresh entered transport")

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var callCount = 0
    private var isReleased = false

    func enter() -> Bool {
        lock.lock()
        callCount += 1
        let isFirst = callCount == 1
        lock.unlock()
        guard isFirst else { return false }
        started.fulfill()
        semaphore.wait()
        return true
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        semaphore.signal()
    }
}

private final class FirstConnectionStageGate: @unchecked Sendable {
    let started: XCTestExpectation

    private let stage: ConnectionStage
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var hasBlocked = false
    private var isReleased = false

    init(stage: ConnectionStage) {
        self.stage = stage
        self.started = XCTestExpectation(description: "first \(stage) request entered transport")
    }

    func blockIfFirstMatching(_ operation: String) -> Bool {
        lock.lock()
        let shouldBlock = operation == stage.rawValue && !hasBlocked
        if shouldBlock {
            hasBlocked = true
        }
        lock.unlock()
        guard shouldBlock else { return false }
        started.fulfill()
        semaphore.wait()
        return true
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        semaphore.signal()
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

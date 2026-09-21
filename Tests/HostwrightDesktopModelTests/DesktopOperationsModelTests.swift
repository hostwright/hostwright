import XCTest
@testable import HostwrightDesktopModel
import HostwrightControlPlane
import HostwrightControlTransport
import HostwrightCore

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

    func testAPIUsesSelectedManifestThroughAuthenticatedCLIControlRoute() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let manifestURL = temporaryDirectory.appendingPathComponent("hostwright.yaml")
        try Data("version: 3\nproject: selected\nservices:\n  web:\n    image: local/selected:latest\n    resources:\n      requests: {cpus: 1, memory: 512MiB}\n      limits: {cpus: 1, memory: 512MiB}\n".utf8).write(to: manifestURL)

        let transport = ScriptedTransport { request in
            Self.cliCompleted(
                request: request,
                standardOutput: String(
                    decoding: try! ControlPlaneCanonicalJSON.encode(
                        Self.statusJSON(
                            projectName: "selected",
                            manifestPath: manifestURL.path
                        )
                    ),
                    as: UTF8.self
                )
            )
        }
        let project = try DesktopControlAPIClient(
            transport: transport,
            authorizationScope: { _, _ in
                .init(
                    projectIdentifier: HostwrightResourceUUID.legacy(
                        kind: "project",
                        identifier: "project-selected"
                    ),
                    resourceIdentifier: nil
                )
            }
        )
            .projectStatus(manifestPath: manifestURL.path)
        XCTAssertEqual(project.name, "selected")
        XCTAssertEqual(project.manifestPath, manifestURL.path)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.operation, "status")
        guard case .object(let fields) = request.body,
              case .array(let arguments) = fields["arguments"] else {
            return XCTFail("selected manifest must use the authenticated CLI route")
        }
        XCTAssertEqual(arguments.first, .string("status"))
        XCTAssertEqual(arguments.dropFirst().first, .string(manifestURL.path))
        XCTAssertEqual(fields["authorizationProjectID"], .string(
            HostwrightResourceUUID.legacy(kind: "project", identifier: "project-selected")
        ))
    }

    func testAPIRejectsSelectedManifestResponseForAnotherPath() throws {
        let manifestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-desktop-\(UUID().uuidString).yaml")
        try Data("version: 3\nproject: selected\nservices:\n  web:\n    image: local/selected:latest\n    resources:\n      requests: {cpus: 1, memory: 512MiB}\n      limits: {cpus: 1, memory: 512MiB}\n".utf8).write(to: manifestURL)
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        let transport = ScriptedTransport { request in
            Self.cliCompleted(
                request: request,
                standardOutput: String(
                    decoding: try! ControlPlaneCanonicalJSON.encode(Self.statusJSON(projectName: "selected")),
                    as: UTF8.self
                )
            )
        }

        XCTAssertThrowsError(
            try DesktopControlAPIClient(
                transport: transport,
                authorizationScope: { _, _ in
                    .init(
                        projectIdentifier: HostwrightResourceUUID.legacy(
                            kind: "project",
                            identifier: "project-selected"
                        ),
                        resourceIdentifier: nil
                    )
                }
            )
                .projectStatus(manifestPath: manifestURL.path)
        ) { error in
            XCTAssertEqual((error as? DesktopControlFailure)?.code, "status.manifestMismatch")
        }
    }

    func testAPIRejectsManifestSymlinkDirectoryAndInvalidUTF8() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.yaml")
        let symlink = root.appendingPathComponent("link.yaml")
        let directory = root.appendingPathComponent("directory.yaml", isDirectory: true)
        let invalid = root.appendingPathComponent("invalid.yaml")
        try Data("version: 3\nproject: selected\nservices:\n  web:\n    image: local/selected:latest\n    resources:\n      requests: {cpus: 1, memory: 512MiB}\n      limits: {cpus: 1, memory: 512MiB}\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xff, 0xfe]).write(to: invalid)
        let api = DesktopControlAPIClient(transport: ScriptedTransport { request in
            Self.cliCompleted(request: request, standardOutput: "{}")
        })

        for (path, code) in [
            (symlink.path, "manifest.unreadable"),
            (directory.path, "manifest.unsafeFile"),
            (invalid.path, "manifest.invalidUTF8"),
        ] {
            XCTAssertThrowsError(try api.projectStatus(manifestPath: path)) { error in
                XCTAssertEqual((error as? DesktopControlFailure)?.code, code)
            }
        }
    }

    func testAPIRejectsRelativeSelectedManifestPath() {
        XCTAssertThrowsError(
            try DesktopControlAPIClient(transport: ScriptedTransport { request in
                Self.completed(request: request, result: Self.statusJSON)
            }).projectStatus(manifestPath: "hostwright.yaml")
        ) { error in
            XCTAssertEqual((error as? DesktopControlFailure)?.code, "manifest.invalidPath")
        }
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

    func testModelConnectsToForegroundDaemonWhenManagedServiceStatusIsUnavailable() async throws {
        let transport = ScriptedTransport { request in
            if request.operation == "daemon" {
                return ControlResponseEnvelope(
                    requestID: request.requestID,
                    status: .error,
                    reasonCode: .internalError,
                    error: SanitizedError(
                        code: "cliExitNonZero",
                        message: "The delegated CLI command returned a non-zero exit status."
                    )
                )
            }
            return Self.completed(request: request, result: Self.statusJSON)
        }
        let model = DesktopOperationsModel(transport: transport)

        model.connect()
        await model.connectionTaskForTesting?.value

        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertNil(model.daemonHealth)
        XCTAssertEqual(model.projects.first?.name, "demo")
        XCTAssertNil(model.lastFailure)
        XCTAssertEqual(transport.requests.map(\.operation), ["daemon", "status"])
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
        healthGate.release()
        await fulfillment(of: [statusGate.started], timeout: 1)

        model.connect()
        guard let replacementTask = model.connectionTaskForTesting else {
            return XCTFail("The model did not retain the replacement connection task.")
        }
        await replacementTask.value

        XCTAssertNil(model.connectionTaskForTesting)
        XCTAssertEqual(model.projects.first?.name, "demo")
        XCTAssertNil(model.lastFailure)

        statusGate.release()
        await supersededTask.value

        XCTAssertEqual(model.connectionState, .connected)
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

    func testSelectingManifestClearsOldProjectAuthorityWhenReplacementStatusFails() async throws {
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

        model.connect()
        for _ in 0..<20 {
            if model.connectionState == .connected && !model.projects.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.projects.first?.id, "project-demo")
        let context = DesktopActionAvailabilityContext(projectID: "project-demo")
        XCTAssertEqual(
            model.actionAvailability(
                for: DesktopAccessibilityIdentifier.lifecycleUp,
                context: context
            ).state,
            .available
        )

        let invalidPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-missing-\(UUID().uuidString).yaml")
            .path
        model.selectManifest(at: invalidPath)

        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(
            model.actionAvailability(
                for: DesktopAccessibilityIdentifier.lifecycleUp,
                context: context
            ).reason,
            .requiresProject
        )
        XCTAssertEqual(
            model.actionAvailability(
                for: DesktopAccessibilityIdentifier.selectedLogsOpen,
                context: DesktopActionAvailabilityContext(
                    projectID: "project-demo",
                    serviceID: "web"
                )
            ).reason,
            .requiresProject
        )

        for _ in 0..<20 {
            if model.lastFailure?.code == "manifest.unreadable" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.lastFailure?.code, "manifest.unreadable")
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(
            model.actionAvailability(
                for: DesktopAccessibilityIdentifier.lifecycleUp,
                context: context
            ).reason,
            .requiresProject
        )
    }

    func testLifecycleAPIUsesManifestBoundPreviewAndExactConfirmationRoutes() throws {
        let hashA = String(repeating: "a", count: 64)
        let hashB = String(repeating: "b", count: 64)
        let hashC = String(repeating: "c", count: 64)
        let group = "11111111-1111-4111-8111-111111111111"
        let transport = ScriptedTransport { request in
            let arguments = Self.arguments(from: request)
            if arguments.contains("--dry-run") {
                return Self.cliCompleted(
                    request: request,
                    standardOutput: Self.lifecyclePlanJSON(
                        action: "up",
                        manifestSHA256: hashA,
                        observationSHA256: hashB,
                        planSHA256: hashC
                    )
                )
            }
            return Self.cliCompleted(
                request: request,
                standardOutput: Self.lifecycleResultJSON(
                    groupID: group,
                    planSHA256: hashC
                )
            )
        }
        let api = DesktopControlAPIClient(transport: transport)
        let cancellation = PersistentControlRequestCancellation()
        let manifest = "/Users/tester/project.yml"
        let authorizationProjectID = "6842e97d-8bc8-8119-92c6-6af3d6c16104"

        let plan = try api.lifecyclePreview(
            action: .up,
            manifestPath: manifest,
            authorizationProjectID: authorizationProjectID,
            cancellation: cancellation
        )
        XCTAssertEqual(plan.action, .up)
        XCTAssertEqual(plan.manifestPath, manifest)
        XCTAssertEqual(plan.manifestSHA256, hashA)
        XCTAssertEqual(plan.observationSHA256, hashB)
        XCTAssertEqual(plan.planSHA256, hashC)
        XCTAssertEqual(plan.nodes.map(\.action), ["create"])

        let result = try api.executeLifecycle(
            plan: plan,
            authorizationProjectID: authorizationProjectID,
            cancellation: cancellation
        )
        XCTAssertEqual(result.groupID, group)
        XCTAssertEqual(result.planSHA256, hashC)
        XCTAssertEqual(result.completedNodeKeys, ["create-web"])
        XCTAssertEqual(
            transport.requests.map(Self.arguments(from:)),
            [
                ["up", manifest, "--dry-run", "--output", "json"],
                ["up", manifest, "--confirm-plan", hashC, "--output", "json"],
            ]
        )
        for request in transport.requests {
            XCTAssertEqual(request.idempotencyKey, request.requestID)
            guard case .object(let body)? = request.body else {
                return XCTFail("Expected a scoped lifecycle request body.")
            }
            XCTAssertEqual(
                body["authorizationProjectID"],
                .string(authorizationProjectID)
            )
            XCTAssertEqual(body["authorizationResourceID"], .null)
        }
    }

    func testLifecycleModelRejectsDuplicateAndStaleConfirmationThenExecutesExactPlan() async throws {
        let planSHA256 = String(repeating: "c", count: 64)
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
            if request.operation == "status" {
                return Self.completed(request: request, result: Self.statusJSON)
            }
            let arguments = Self.arguments(from: request)
            if arguments.contains("--dry-run") {
                return Self.cliCompleted(
                    request: request,
                    standardOutput: Self.lifecyclePlanJSON(
                        action: "up",
                        manifestSHA256: String(repeating: "a", count: 64),
                        observationSHA256: String(repeating: "b", count: 64),
                        planSHA256: planSHA256
                    )
                )
            }
            return Self.cliCompleted(
                request: request,
                standardOutput: Self.lifecycleResultJSON(
                    groupID: "11111111-1111-4111-8111-111111111111",
                    planSHA256: planSHA256
                )
            )
        }
        let model = DesktopOperationsModel(transport: transport)
        model.connect()
        await model.connectionTaskForTesting?.value

        model.previewLifecycle(.up, manifestPath: "/Users/tester/project.yml")
        await model.lifecycleTaskForTesting?.value
        guard case .awaitingConfirmation(let plan) = model.lifecycleState else {
            return XCTFail("Expected a reviewed lifecycle plan.")
        }
        let countAfterPreview = transport.requests.count
        model.previewLifecycle(.down, manifestPath: "/Users/tester/project.yml")
        XCTAssertEqual(transport.requests.count, countAfterPreview)

        model.confirmLifecycle(planSHA256: String(repeating: "d", count: 64))
        XCTAssertEqual(model.lifecycleState, .idle)
        XCTAssertEqual(model.lastFailure?.code, "lifecycle.staleConfirmation")

        model.previewLifecycle(.up, manifestPath: "/Users/tester/project.yml")
        await model.lifecycleTaskForTesting?.value
        model.confirmLifecycle(planSHA256: plan.planSHA256)
        model.confirmLifecycle(planSHA256: plan.planSHA256)
        await model.lifecycleTaskForTesting?.value
        guard case .succeeded(let result) = model.lifecycleState else {
            return XCTFail("Expected exact confirmed lifecycle success.")
        }
        XCTAssertEqual(result.planSHA256, planSHA256)
        XCTAssertEqual(
            transport.requests.filter { Self.arguments(from: $0).contains("--confirm-plan") }.count,
            1
        )
        let lifecycleRequests = transport.requests.filter {
            ["up", "down", "restart"].contains($0.operation)
        }
        XCTAssertFalse(lifecycleRequests.isEmpty)
        for request in lifecycleRequests {
            guard case .object(let body)? = request.body else {
                return XCTFail("Expected a scoped lifecycle request body.")
            }
            XCTAssertEqual(
                body["authorizationProjectID"],
                .string("6842e97d-8bc8-8119-92c6-6af3d6c16104")
            )
            XCTAssertEqual(request.idempotencyKey, request.requestID)
        }
    }

    func testLifecycleCancellationAndDisconnectCloseTheActiveControlRequest() async {
        for disconnect in [false, true] {
            let transport = CancellableLifecycleTransport(
                daemonResponse: Self.daemonHealthJSON,
                statusResponse: Self.statusJSON
            )
            let model = DesktopOperationsModel(transport: transport)
            model.connect()
            await model.connectionTaskForTesting?.value
            model.previewLifecycle(.restart, manifestPath: "/Users/tester/project.yml")
            await fulfillment(of: [transport.started], timeout: 1)
            let task = model.lifecycleTaskForTesting

            if disconnect {
                model.disconnect()
                XCTAssertEqual(model.connectionState, .disconnected)
                XCTAssertEqual(model.lifecycleState, .idle)
            } else {
                model.cancelLifecycle()
                XCTAssertEqual(model.lifecycleState, .cancelled(.restart))
            }
            await task?.value
            XCTAssertTrue(transport.observedCancellation)
            XCTAssertNil(model.lastFailure)
        }
    }

    func testStatusRefreshKeepsDistinctActionHashButInvalidatesChangedStatusHash() async {
        let statuses = LifecycleStatusSequence([
            Self.statusJSON, Self.statusJSON,
            Self.statusJSON(projectName: "demo", planHash: "sha256:changed"),
        ])
        let actionHash = String(repeating: "c", count: 64)
        let transport = ScriptedTransport { request in
            if request.operation == "daemon" {
                return Self.connectionResponse(request: request, generation: 3, projectName: "demo")
            }
            if request.operation == "status" {
                return Self.completed(request: request, result: statuses.next())
            }
            return Self.cliCompleted(request: request, standardOutput: Self.lifecyclePlanJSON(
                action: "down", manifestSHA256: String(repeating: "a", count: 64),
                observationSHA256: String(repeating: "b", count: 64), planSHA256: actionHash
            ))
        }
        let model = DesktopOperationsModel(transport: transport)
        model.connect()
        await model.connectionTaskForTesting?.value
        model.previewLifecycle(.down, manifestPath: "/Users/tester/project.yml")
        await model.lifecycleTaskForTesting?.value
        guard case .awaitingConfirmation(let plan) = model.lifecycleState else {
            return XCTFail("Expected a review even though status and action hashes differ.")
        }
        XCTAssertNotEqual(model.projects.first?.planHash, plan.planSHA256)
        model.refreshStatus()
        await model.statusRefreshTaskForTesting?.value
        XCTAssertEqual(model.lifecycleState, .awaitingConfirmation(plan))
        model.refreshStatus()
        await model.statusRefreshTaskForTesting?.value
        XCTAssertEqual(model.lifecycleState, .idle)
        XCTAssertEqual(model.lastFailure?.code, "lifecycle.staleConfirmation")
        model.confirmLifecycle(planSHA256: actionHash)
        XCTAssertFalse(transport.requests.contains { Self.arguments(from: $0).contains("--confirm-plan") })
    }

    func testCancellingExecutingLifecycleClosesRequestAndFencesFailure() async {
        let hash = String(repeating: "c", count: 64)
        let transport = CancellableLifecycleTransport(
            daemonResponse: Self.daemonHealthJSON, statusResponse: Self.statusJSON,
            previewResponse: Self.lifecyclePlanJSON(
                action: "up", manifestSHA256: String(repeating: "a", count: 64),
                observationSHA256: String(repeating: "b", count: 64), planSHA256: hash
            )
        )
        let model = DesktopOperationsModel(transport: transport)
        model.connect()
        await model.connectionTaskForTesting?.value
        model.previewLifecycle(.up, manifestPath: "/Users/tester/project.yml")
        await model.lifecycleTaskForTesting?.value
        model.confirmLifecycle(planSHA256: hash)
        await fulfillment(of: [transport.started], timeout: 1)
        guard case .executing = model.lifecycleState else {
            model.cancelLifecycle()
            return XCTFail("Expected execution before cancellation.")
        }
        let executionTask = model.lifecycleTaskForTesting
        model.cancelLifecycle()
        await executionTask?.value
        XCTAssertTrue(transport.observedCancellation)
        XCTAssertEqual(model.lifecycleState, .cancelled(.up))
        XCTAssertNil(model.lastFailure)
    }

    func testCancellingReviewedPlanSendsNoExecutionRequest() async {
        let hash = String(repeating: "c", count: 64)
        let transport = ScriptedTransport { request in
            if ["daemon", "status"].contains(request.operation) {
                return Self.connectionResponse(request: request, generation: 3, projectName: "demo")
            }
            return Self.cliCompleted(request: request, standardOutput: Self.lifecyclePlanJSON(
                action: "restart", manifestSHA256: String(repeating: "a", count: 64),
                observationSHA256: String(repeating: "b", count: 64), planSHA256: hash
            ))
        }
        let model = DesktopOperationsModel(transport: transport)
        model.connect()
        await model.connectionTaskForTesting?.value
        model.previewLifecycle(.restart, manifestPath: "/Users/tester/project.yml")
        await model.lifecycleTaskForTesting?.value
        guard case .awaitingConfirmation = model.lifecycleState else {
            return XCTFail("Expected a plan before cancellation.")
        }
        model.cancelLifecycle()
        model.confirmLifecycle(planSHA256: hash)
        XCTAssertEqual(model.lifecycleState, .cancelled(.restart))
        XCTAssertFalse(transport.requests.contains { Self.arguments(from: $0).contains("--confirm-plan") })
    }

    func testLatePreviewCannotPresentReviewForReplacedProject() async {
        let statuses = LifecycleStatusSequence([Self.statusJSON, Self.statusJSON(projectName: "replacement")])
        let gate = LifecyclePreviewGate()
        defer { gate.release() }
        let transport = ScriptedTransport { request in
            if request.operation == "daemon" {
                return Self.connectionResponse(request: request, generation: 3, projectName: "demo")
            }
            if request.operation == "status" {
                return Self.completed(request: request, result: statuses.next())
            }
            gate.wait()
            return Self.cliCompleted(request: request, standardOutput: Self.lifecyclePlanJSON(
                action: "up", manifestSHA256: String(repeating: "a", count: 64),
                observationSHA256: String(repeating: "b", count: 64),
                planSHA256: String(repeating: "c", count: 64)
            ))
        }
        let model = DesktopOperationsModel(transport: transport)
        model.connect()
        await model.connectionTaskForTesting?.value
        model.previewLifecycle(.up, manifestPath: "/Users/tester/project.yml")
        let previewTask = model.lifecycleTaskForTesting
        await fulfillment(of: [gate.started], timeout: 1)
        model.refreshStatus()
        await model.statusRefreshTaskForTesting?.value
        gate.release()
        await previewTask?.value
        XCTAssertEqual(model.projects.first?.name, "replacement")
        XCTAssertEqual(model.lifecycleState, .idle)
        XCTAssertEqual(model.lastFailure?.code, "lifecycle.staleConfirmation")
    }

    func testReconnectCancelsBothStreamsAndFencesLateSnapshots() async {
        let streams = ConcurrentStreamHarness()
        defer { streams.releaseAll() }
        let model = DesktopOperationsModel(transport: ScriptedTransport(
            responseProvider: { request in
                Self.connectionResponse(request: request, generation: 3, projectName: "demo")
            }, sessionProvider: { streams.makeSession() }
        ))
        model.connect()
        await model.connectionTaskForTesting?.value
        model.startEventStream()
        model.openLogStream(for: "web")
        let eventTask = model.eventStreamTaskForTesting
        let logTask = model.logStreamTaskForTesting
        await fulfillment(of: [streams.eventStarted, streams.logStarted], timeout: 1)
        model.reconnect()
        XCTAssertFalse(model.isEventStreamRunning)
        XCTAssertFalse(model.isLogStreamRunning)
        streams.releaseAll()
        await eventTask?.value
        await logTask?.value
        await model.connectionTaskForTesting?.value
        XCTAssertEqual(Set(streams.cancelledSources), Set([.events, .logs]))
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertTrue(model.logChunks.isEmpty)
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

    nonisolated private static func statusJSON(
        projectName: String,
        planHash: String = "sha256:plan",
        manifestPath: String = "/Users/tester/project.yml"
    ) -> ControlPlaneJSONValue {
        .object([
            "manifest": .object([
                "exists": .bool(true),
                "path": .string(manifestPath),
                "valid": .bool(true),
            ]),
            "planHash": .string(planHash),
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

    nonisolated private static func cliCompleted(
        request: ControlRequestEnvelope,
        standardOutput: String
    ) -> ControlResponseEnvelope {
        completed(
            request: request,
            result: .object([
                "exitCode": .integer(0),
                "resultSchemaVersion": .integer(1),
                "standardError": .string(""),
                "standardOutput": .string(standardOutput),
            ])
        )
    }

    nonisolated private static func arguments(
        from request: ControlRequestEnvelope
    ) -> [String] {
        guard case .object(let fields)? = request.body,
              case .array(let values)? = fields["arguments"] else { return [] }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }

    nonisolated private static func lifecyclePlanJSON(
        action: String,
        manifestSHA256: String,
        observationSHA256: String,
        planSHA256: String
    ) -> String {
        """
        {"schemaVersion":1,"command":"\(action)","manifestSHA256":"\(manifestSHA256)","observationSHA256":"\(observationSHA256)","planSHA256":"\(planSHA256)","projectName":"demo","nodes":[{"key":"create-web","action":"create","serviceName":"demo/web","resourceIdentifier":"resource-web"}]}
        """
    }

    nonisolated private static func lifecycleResultJSON(
        groupID: String,
        planSHA256: String
    ) -> String {
        """
        {"checkpoint":"verified","completedNodeKeys":["create-web"],"groupID":"\(groupID)","kind":"lifecycle-result","planSHA256":"\(planSHA256)","status":"succeeded"}
        """
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

private final class LifecyclePreviewGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "preview waits for status replacement")
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        started.fulfill()
        _ = semaphore.wait(timeout: .now() + 5)
    }

    func release() { semaphore.signal() }
}

private final class LifecycleStatusSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ControlPlaneJSONValue]

    init(_ values: [ControlPlaneJSONValue]) { self.values = values }

    func next() -> ControlPlaneJSONValue {
        lock.lock()
        defer { lock.unlock() }
        return values.count > 1 ? values.removeFirst() : values[0]
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

private final class CancellableLifecycleTransport: DesktopControlTransport, @unchecked Sendable {
    let started = XCTestExpectation(description: "lifecycle request entered transport")

    private let daemonResponse: String
    private let statusResponse: ControlPlaneJSONValue
    private let previewResponse: String?
    private let lock = NSLock()
    private var didObserveCancellation = false

    init(daemonResponse: String, statusResponse: ControlPlaneJSONValue, previewResponse: String? = nil) {
        self.daemonResponse = daemonResponse
        self.statusResponse = statusResponse
        self.previewResponse = previewResponse
    }

    var observedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didObserveCancellation
    }

    func send(_ request: ControlRequestEnvelope) throws -> ControlResponseEnvelope {
        if request.operation == "daemon" {
            return ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: .object([
                    "exitCode": .integer(0),
                    "resultSchemaVersion": .integer(1),
                    "standardError": .string(""),
                    "standardOutput": .string(daemonResponse),
                ])
            )
        }
        return ControlResponseEnvelope(
            requestID: request.requestID,
            status: .completed,
            reasonCode: .completed,
            result: statusResponse
        )
    }

    func send(
        _ request: ControlRequestEnvelope,
        cancellation: PersistentControlRequestCancellation
    ) throws -> ControlResponseEnvelope {
        if let previewResponse, case .object(let body)? = request.body,
           case .array(let arguments)? = body["arguments"],
           arguments.contains(.string("--dry-run")) {
            return ControlResponseEnvelope(
                requestID: request.requestID, status: .completed, reasonCode: .completed,
                result: .object([
                    "exitCode": .integer(0), "resultSchemaVersion": .integer(1),
                    "standardError": .string(""), "standardOutput": .string(previewResponse),
                ])
            )
        }
        started.fulfill()
        while !cancellation.isCancelled {
            usleep(1_000)
        }
        lock.lock()
        didObserveCancellation = true
        lock.unlock()
        throw PersistentControlClientError.connectionClosed
    }

    func connectSession() throws -> any DesktopControlSession {
        throw DesktopControlFailure(code: "test.noSession", message: "No stream session.")
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

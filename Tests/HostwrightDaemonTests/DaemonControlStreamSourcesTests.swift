import Foundation
import CryptoKit
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightControlSecurity
@testable import HostwrightControlTransport
@testable import HostwrightCommandTransport
@testable import HostwrightCLI
@testable import HostwrightDaemon
@testable import HostwrightManifest
@testable import HostwrightObservability
@testable import HostwrightRuntime
@testable import HostwrightState

final class DaemonControlStreamSourcesTests: XCTestCase {
  func testCLIStreamPreparationBindsRelativeManifestToClientWorkingDirectory() throws {
    try withFixture { fixture in
      try fixture.store.ownership.upsert(streamOwnership())
      let savedProject = try fixture.store.desiredStates.loadProject(id: "project-stream-tests")
      XCTAssertEqual(savedProject.resourceUUID, "11111111-1111-4111-8111-111111111111")
      XCTAssertEqual(savedProject.mutationProvider, "apple-container-cli")
      XCTAssertEqual(savedProject.providerGeneration, 1)
      let workingDirectory = URL(fileURLWithPath: fixture.store.path)
        .deletingLastPathComponent().path
      let route = try CLIControlRoute.classify(arguments: [
        "logs", "api", "hostwright.yaml",
        "--state-db", fixture.store.path,
      ]).withWorkingDirectory(workingDirectory)
        .withAuthorizationScope(CLIControlAuthorizationScope(
          projectIdentifier: "11111111-1111-4111-8111-111111111111",
          resourceIdentifier: "22222222-2222-4222-8222-222222222222"
        ))

      let preparation = try fixture.factory.prepare(
        peer: fixture.owner,
        route: route,
        environment: .live
      )

      guard case .object(let filter)? = preparation.filter else {
        return XCTFail("Expected a bounded log preparation filter.")
      }
      XCTAssertEqual(
        filter["manifestPath"],
        .string(URL(fileURLWithPath: workingDirectory)
          .appendingPathComponent("hostwright.yaml").path)
      )
      XCTAssertEqual(filter["serviceName"], .string("api"))
      XCTAssertEqual(preparation.target, "22222222-2222-4222-8222-222222222222")
    }
  }

  func testEventsDeliverInOrderAndResumeWithSignedSubjectAndFilterBoundCursor() throws {
    try withFixture { fixture in
      try fixture.store.events.append([
        event("event-1", timestamp: "2026-08-03T00:00:01Z", severity: .warning),
        event("event-ignored", timestamp: "2026-08-03T00:00:02Z", severity: .info),
        event("event-2", timestamp: "2026-08-03T00:00:03Z", severity: .warning),
      ])
      let request = ControlStreamOpenRequest(
        source: .events,
        filter: .object(["severity": .string("warning")])
      )
      XCTAssertEqual(
        try fixture.store.events.streamPage(
          after: nil,
          filter: HostwrightEventStreamFilter(severity: .warning)
        ).events.map(\.event.id),
        ["event-1", "event-2"]
      )
      let first = EmissionCollector(dataCount: 1, terminateWhenSatisfied: true)
      let firstHandle = try fixture.factory.open(
        peer: fixture.owner,
        request: request,
        cursor: nil,
        preStartAuthorization: {},
        sink: first.receive
      )
      XCTAssertEqual(first.wait(), .success)
      firstHandle.cancel()

      XCTAssertEqual(first.dataIDs, ["event-1"])
      let cursor = try XCTUnwrap(first.dataCursors.first)
      let resumed = EmissionCollector(dataCount: 1, terminateWhenSatisfied: true)
      let resumedHandle = try fixture.factory.open(
        peer: fixture.owner,
        request: request,
        cursor: cursor,
        preStartAuthorization: {},
        sink: resumed.receive
      )
      XCTAssertEqual(resumed.wait(), .success)
      resumedHandle.cancel()

      XCTAssertEqual(resumed.dataIDs, ["event-2"])
      XCTAssertTrue(Set(first.dataIDs).isDisjoint(with: resumed.dataIDs))
    }
  }

  func testStateTraceAndOperationSourcesApplyTheirRequiredFiltering() throws {
    try withFixture { fixture in
      try fixture.store.events.append([
        event("state-alpha", type: "state.alpha"),
        event("state-beta", type: "state.beta"),
        event("trace-1", type: HostwrightTraceContract.eventType, source: HostwrightTraceContract.source),
        event("operation-match", type: "operation.succeeded", payload: #"{"operationID":"operation-1"}"#),
        event("operation-other", type: "operation.succeeded", payload: #"{"operationID":"operation-2"}"#),
      ])

      let state = EmissionCollector(dataCount: 1, terminateWhenSatisfied: true)
      let stateHandle = try fixture.factory.open(
        peer: fixture.owner,
        request: ControlStreamOpenRequest(
          source: .state,
          filter: .object(["type": .string("state.alpha")])
        ),
        cursor: nil,
        preStartAuthorization: {},
        sink: state.receive
      )
      XCTAssertEqual(state.wait(), .success)
      stateHandle.cancel()
      XCTAssertEqual(state.dataIDs, ["state-alpha"])

      let trace = EmissionCollector(dataCount: 1, terminateWhenSatisfied: true)
      let traceHandle = try fixture.factory.open(
        peer: fixture.owner,
        request: ControlStreamOpenRequest(source: .traces),
        cursor: nil,
        preStartAuthorization: {},
        sink: trace.receive
      )
      XCTAssertEqual(trace.wait(), .success)
      traceHandle.cancel()
      XCTAssertEqual(trace.dataIDs, ["trace-1"])

      let operation = EmissionCollector(dataCount: 1, terminateWhenSatisfied: true)
      let operationHandle = try fixture.factory.open(
        peer: fixture.owner,
        request: ControlStreamOpenRequest(source: .operation, target: "operation-1"),
        cursor: nil,
        preStartAuthorization: {},
        sink: operation.receive
      )
      XCTAssertEqual(operation.wait(), .success)
      operationHandle.cancel()
      XCTAssertEqual(operation.dataIDs, ["operation-match"])
    }
  }

  func testCompactedRawCursorReturnsSignedFrameAndResumableRawRecoveryHints() throws {
    try withFixture { fixture in
      try fixture.store.events.append([event("event-1"), event("event-2")])
      let rawCursor = try XCTUnwrap(
        try fixture.store.events.streamPage(after: nil, pageSize: 1).nextCursor
      )
      let request = ControlStreamOpenRequest(source: .events)
      let binding = try binding(for: fixture.owner, request: request)
      let signedCursor = try fixture.cursorCodec.issue(binding: binding, sourceCursor: rawCursor)
      try fixture.store.withValidatedConnection { connection in
        try connection.run("DELETE FROM event_ledger WHERE id = ?", bindings: [.text("event-1")])
      }
      let rawGap = try fixture.store.events.streamPage(after: rawCursor)
        .retentionGap

      let collector = EmissionCollector(gapCount: 1, terminateWhenSatisfied: true)
      let handle = try fixture.factory.open(
        peer: fixture.owner,
        request: request,
        cursor: signedCursor,
        preStartAuthorization: {},
        sink: collector.receive
      )
      XCTAssertEqual(collector.wait(), .success)
      handle.cancel()

      let gap = try XCTUnwrap(collector.gaps.first)
      XCTAssertEqual(gap.reason, "retention.compacted")
      XCTAssertTrue(gap.requiresAcknowledgement)
      let earliest = try XCTUnwrap(gap.earliestCursor)
      let latest = try XCTUnwrap(gap.latestCursor)
      XCTAssertEqual(earliest, rawGap?.earliestAvailableCursor)
      XCTAssertEqual(latest, rawGap?.latestAvailableCursor)
      XCTAssertNoThrow(try HostwrightEventCursor(token: earliest))
      XCTAssertNoThrow(try HostwrightEventCursor(token: latest))
      let signedFrameCursor = try XCTUnwrap(collector.gapCursors.first)
      XCTAssertEqual(
        try fixture.cursorCodec.verify(signedFrameCursor, expectedBinding: binding).sourceCursor,
        rawGap?.earliestAvailableCursor
      )
    }
  }

  func testMetricsEmitsInitialSnapshotThenStopsOnCancellation() throws {
    try withFixture { fixture in
      XCTAssertNoThrow(try StateMetricsService(store: fixture.store).snapshot())
      let collector = EmissionCollector(dataCount: 1)
      let request = ControlStreamOpenRequest(source: .metrics)
      let handle = try fixture.factory.open(
        peer: fixture.owner,
        request: request,
        cursor: nil,
        preStartAuthorization: {},
        sink: collector.receive
      )
      XCTAssertEqual(collector.wait(), .success)
      handle.cancel()

      XCTAssertEqual(collector.dataCount, 1)
      let cursor = try XCTUnwrap(collector.dataCursors.first)
      XCTAssertNoThrow(try fixture.cursorCodec.verify(
        cursor,
        expectedBinding: try binding(for: fixture.owner, request: request)
      ))
    }
  }

  func testRejectsCrossSubjectCursorAndInvalidFilters() throws {
    try withFixture { fixture in
      let request = ControlStreamOpenRequest(source: .events)
      let ownerBinding = try binding(for: fixture.owner, request: request)
      let ownerCursor = try fixture.cursorCodec.issue(
        binding: ownerBinding,
        sourceCursor: "hwe1.eyJldmVudElEIjoiZXZlbnQtMSIsImV2ZW50U0hBMjU2IjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYYSIsInNjaGVtYVZlcnNpb24iOjF9"
      )
      let collector = EmissionCollector(dataCount: 1)

      XCTAssertThrowsError(try fixture.factory.open(
        peer: fixture.operatorPeer,
        request: request,
        cursor: ownerCursor,
        preStartAuthorization: {},
        sink: collector.receive
      )) { error in
        XCTAssertEqual(error as? ControlStreamCursorError, .bindingMismatch)
      }
      XCTAssertThrowsError(try fixture.factory.open(
        peer: fixture.owner,
        request: ControlStreamOpenRequest(source: .events, filter: .string("invalid")),
        cursor: nil,
        preStartAuthorization: {},
        sink: collector.receive
      )) { error in
        XCTAssertTrue(error is DaemonControlStreamSourceError)
      }
    }
  }

  func testAttachAndExecRejectUnknownServiceDuringPreparation() throws {
    try withFixture { fixture in
      let collector = EmissionCollector(dataCount: 1)
      let requests = [
        ControlStreamOpenRequest(source: .attach, target: "missing-service"),
        ControlStreamOpenRequest(
          source: .exec,
          target: "missing-service",
          filter: .object(["arguments": .array([.string("/usr/bin/true")])])
        ),
      ]
      for request in requests {
        XCTAssertThrowsError(try fixture.factory.open(
          peer: fixture.owner,
          request: request,
          cursor: nil,
          preStartAuthorization: {},
          sink: collector.receive
        ))
      }
    }
  }

  func testLogsValidationDistinguishesFiniteAndFollowingFiltersWithoutMutationIdentity() throws {
    try withFixture { fixture in
      try fixture.store.ownership.upsert(streamOwnership())
      let finite = followingLogsRequest(follow: false)
      let following = followingLogsRequest(follow: true)

      XCTAssertNoThrow(try fixture.factory.validateRequest(finite))
      XCTAssertNoThrow(try fixture.factory.validateRequest(following))
      XCTAssertThrowsError(try fixture.factory.validateRequest(ControlStreamOpenRequest(
        source: .logs,
        target: "22222222-2222-4222-8222-222222222222",
        filter: .object([
          "serviceName": .string("api"),
          "follow": .bool(true),
          "timeoutSeconds": .integer(300),
        ]),
        requestID: "logs-must-not-mutate",
        idempotencyKey: "logs-must-not-mutate"
      )))
    }
  }

  func testFollowingLogsAreReadOnlyAndHonorPreStartReauthorizationAndCancellation() throws {
    try withFixture { fixture in
      let request = followingLogsRequest(follow: true)
      let binding = try binding(for: fixture.owner, request: request)
      let preStartGate = PreStartAuthorizationGate()
      let revokedTask = PreStartRevocationTask()
      let revokedEmissions = InteractiveEmissionCollector()
      let revokedProducer = try InteractiveControlStreamProducer(
        cursorCodec: fixture.cursorCodec,
        binding: binding,
        request: request,
        sourceCursor: nil,
        manifestPath: "/nonexistent/unused-by-test.yaml",
        stateDatabasePath: fixture.store.path,
        requestRepository: ControlRequestRepository(store: fixture.store),
        auditRecorder: StreamSourceAuditRecorder(),
        subjectID: fixture.owner.binding.subject.identifier,
        preStartAuthorization: { try preStartGate.authorize() },
        prepareTaskOverride: { revokedTask },
        sink: revokedEmissions.receive
      )

      let input = try ControlStreamFrameContract.value(ControlStreamClientInput(
        kind: .stdin,
        payloadBase64: Data("must-not-forward".utf8).base64EncodedString()
      ))
      XCTAssertFalse(revokedProducer.handle.sendInput(input) {})
      preStartGate.revoke()
      revokedProducer.start()
      XCTAssertEqual(revokedEmissions.waitForTerminal(), .success)
      XCTAssertEqual(revokedTask.startCount, 0)
      XCTAssertEqual(revokedTask.cancelCount, 1)
      XCTAssertEqual(revokedEmissions.failureCodes, ["runtimeLogsAuthorizationRevoked"])
      XCTAssertTrue(try fixture.store.operations.loadAll().isEmpty)

      let cancellableTask = CancellableFollowingLogsTask()
      let runningEmissions = InteractiveEmissionCollector()
      let runningProducer = try InteractiveControlStreamProducer(
        cursorCodec: fixture.cursorCodec,
        binding: binding,
        request: request,
        sourceCursor: nil,
        manifestPath: "/nonexistent/unused-by-test.yaml",
        stateDatabasePath: fixture.store.path,
        requestRepository: ControlRequestRepository(store: fixture.store),
        auditRecorder: StreamSourceAuditRecorder(),
        subjectID: fixture.owner.binding.subject.identifier,
        preStartAuthorization: {},
        prepareTaskOverride: { cancellableTask },
        sink: runningEmissions.receive
      )
      runningProducer.start()
      XCTAssertEqual(cancellableTask.waitForStart(), .success)
      XCTAssertFalse(runningProducer.handle.sendInput(input) {})
      runningProducer.handle.cancel()
      XCTAssertEqual(cancellableTask.waitForCancellation(), .success)
      XCTAssertTrue(try fixture.store.operations.loadAll().isEmpty)
    }
  }

  func testValidateRequestRejectsEveryInvalidSourceTargetFilterCrossProduct() throws {
    try withFixture { fixture in
      let runtimeTarget = "22222222-2222-4222-8222-222222222222"
      let runtimeFilter: ControlPlaneJSONValue = .object(["serviceName": .string("api")])
      let invalid: [ControlStreamOpenRequest] = [
        ControlStreamOpenRequest(source: .events, target: runtimeTarget),
        ControlStreamOpenRequest(source: .state, target: runtimeTarget),
        ControlStreamOpenRequest(source: .traces, target: runtimeTarget),
        ControlStreamOpenRequest(source: .metrics, target: runtimeTarget),
        ControlStreamOpenRequest(source: .metrics, filter: .object([:])),
        ControlStreamOpenRequest(
          source: .operation, target: "operation-1", filter: .object(["tail": .integer(1)])),
        ControlStreamOpenRequest(
          source: .logs, target: runtimeTarget,
          filter: .object(["serviceName": .string("api"), "tty": .bool(true)])),
        ControlStreamOpenRequest(
          source: .attach, target: runtimeTarget,
          filter: .object(["serviceName": .string("api"), "tail": .integer(1)]),
          requestID: "attach-invalid", idempotencyKey: "attach-invalid-key"),
        ControlStreamOpenRequest(
          source: .exec, target: runtimeTarget, filter: runtimeFilter,
          requestID: "exec-invalid", idempotencyKey: "exec-invalid-key"),
        ControlStreamOpenRequest(
          source: .logs, target: "55555555-5555-4555-8555-555555555555", filter: runtimeFilter),
      ]
      for request in invalid {
        XCTAssertThrowsError(try fixture.factory.validateRequest(request), "\(request.source)")
      }
    }
  }

  func testLongLivedEventStreamRecoversFromCreditExhaustionWithHeartbeat() throws {
    try withFixture { fixture in
      try fixture.store.events.append([event("recover-after-credit")])
      let collector = CreditRecoveryCollector()
      let request = ControlStreamOpenRequest(source: .events, heartbeatMilliseconds: 1_000)
      let handle = try fixture.factory.open(
        peer: fixture.owner,
        request: request,
        cursor: nil,
        preStartAuthorization: {},
        sink: collector.receive
      )
      defer { handle.cancel() }

      XCTAssertEqual(collector.waitForBlockedData(), .success)
      handle.addCredit(1)
      XCTAssertEqual(collector.waitForRecoveredData(), .success)
      XCTAssertEqual(collector.dataIDs, ["recover-after-credit"])
      XCTAssertGreaterThanOrEqual(collector.heartbeatCount, 1)
    }
  }

  func testBlockedInteractivePreparationCancelsDurablyWithoutWaitingOrDoubleTerminal() throws {
    try withFixture { fixture in
      let enteredPreparation = DispatchSemaphore(value: 0)
      let releasePreparation = DispatchSemaphore(value: 0)
      let audit = StreamSourceAuditRecorder()
      let emissions = InteractiveEmissionCollector()
      let request = interactiveRequest(requestID: "blocked-prepare", idempotencyKey: "blocked-key")
      let producer = try makeInteractiveProducer(
        fixture: fixture,
        request: request,
        audit: audit,
        prepare: {
          enteredPreparation.signal()
          _ = releasePreparation.wait(timeout: .now() + 5)
        },
        sink: emissions.receive
      )

      let startedAt = Date()
      producer.start()
      XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.1)
      XCTAssertEqual(enteredPreparation.wait(timeout: .now() + 1), .success)

      try fixture.store.events.append([event("independent-source", type: "test.independent")])
      let independent = EmissionCollector(dataCount: 1, terminateWhenSatisfied: true)
      let independentHandle = try fixture.factory.open(
        peer: fixture.owner,
        request: ControlStreamOpenRequest(
          source: .state,
          filter: .object(["type": .string("test.independent")])
        ),
        cursor: nil,
        preStartAuthorization: {},
        sink: independent.receive
      )
      XCTAssertEqual(independent.wait(), .success)
      independentHandle.cancel()
      XCTAssertEqual(independent.dataIDs, ["independent-source"])

      producer.handle.cancel()
      XCTAssertEqual(emissions.waitForTerminal(), .success)
      assertCancelledBeforeStartEvidence(
        fixture: fixture,
        request: request,
        audit: audit,
        emissions: emissions
      )

      releasePreparation.signal()
      XCTAssertEqual(emissions.waitForQuietPeriod(), .timedOut)
      XCTAssertEqual(emissions.terminalCount, 1)
    }
  }

  func testCancelDuringPreparationDropsBufferedInputWithoutAcknowledgingIt() throws {
    try withFixture { fixture in
      let enteredPreparation = DispatchSemaphore(value: 0)
      let releasePreparation = DispatchSemaphore(value: 0)
      let inputAcknowledged = DispatchSemaphore(value: 0)
      let audit = StreamSourceAuditRecorder()
      let emissions = InteractiveEmissionCollector()
      let request = interactiveRequest(requestID: "prepare-input-race", idempotencyKey: "prepare-input-key")
      let producer = try makeInteractiveProducer(
        fixture: fixture,
        request: request,
        audit: audit,
        prepare: {
          enteredPreparation.signal()
          _ = releasePreparation.wait(timeout: .now() + 5)
        },
        sink: emissions.receive
      )

      producer.start()
      XCTAssertEqual(enteredPreparation.wait(timeout: .now() + 1), .success)
      let input = try ControlStreamFrameContract.value(ControlStreamClientInput(
        kind: .stdin,
        payloadBase64: Data("race-input".utf8).base64EncodedString()
      ))
      XCTAssertTrue(producer.handle.sendInput(input) { inputAcknowledged.signal() })

      producer.handle.cancel()
      XCTAssertEqual(emissions.waitForTerminal(), .success)
      XCTAssertEqual(inputAcknowledged.wait(timeout: .now() + 0.2), .timedOut)
      assertCancelledBeforeStartEvidence(
        fixture: fixture,
        request: request,
        audit: audit,
        emissions: emissions
      )

      releasePreparation.signal()
      XCTAssertEqual(emissions.waitForQuietPeriod(), .timedOut)
      XCTAssertEqual(emissions.terminalCount, 1)
      XCTAssertEqual(inputAcknowledged.wait(timeout: .now() + 0.2), .timedOut)
    }
  }

  func testRevokedPreStartAuthorizationAfterBlockedPreparationCancelsTaskAndPreservesDurableDenial() throws {
    try withFixture { fixture in
      let enteredPreparation = DispatchSemaphore(value: 0)
      let releasePreparation = DispatchSemaphore(value: 0)
      let inputAcknowledged = DispatchSemaphore(value: 0)
      let preStartGate = PreStartAuthorizationGate()
      let audit = StreamSourceAuditRecorder()
      let emissions = InteractiveEmissionCollector()
      let preparedTask = PreStartRevocationTask()
      let request = interactiveRequest(
        requestID: "prestart-revoked",
        idempotencyKey: "prestart-revoked-key"
      )
      let producer = try makeInteractiveProducer(
        fixture: fixture,
        request: request,
        audit: audit,
        prepareTask: {
          enteredPreparation.signal()
          _ = releasePreparation.wait(timeout: .now() + 5)
          return preparedTask
        },
        preStartAuthorization: { try preStartGate.authorize() },
        sink: emissions.receive
      )

      producer.start()
      XCTAssertEqual(enteredPreparation.wait(timeout: .now() + 1), .success)
      let input = try ControlStreamFrameContract.value(ControlStreamClientInput(
        kind: .stdin,
        payloadBase64: Data("must-not-be-consumed".utf8).base64EncodedString()
      ))
      XCTAssertTrue(producer.handle.sendInput(input) { inputAcknowledged.signal() })

      preStartGate.revoke()
      releasePreparation.signal()

      XCTAssertEqual(emissions.waitForTerminal(), .success)
      XCTAssertEqual(preparedTask.startCount, 0)
      XCTAssertEqual(preparedTask.cancelCount, 1)
      XCTAssertEqual(inputAcknowledged.wait(timeout: .now() + 0.2), .timedOut)
      XCTAssertEqual(
        try? ControlRequestRepository(store: fixture.store).load(request.requestID!)?.status,
        .error
      )
      let operationReference = interactiveOperationReference(
        subjectID: fixture.owner.binding.subject.identifier,
        requestID: request.requestID!
      )
      XCTAssertEqual(
        try? fixture.store.operations.loadAll().first(where: { $0.id == operationReference })?.status,
        .abandoned
      )
      let stages = ((try? fixture.store.events.streamPage(after: nil, pageSize: 100).events) ?? [])
        .map { $0.event.type }
        .filter { $0.hasPrefix("operation.stream.") }
      XCTAssertEqual(stages, [
        "operation.stream.planned", "operation.stream.cancel-requested", "operation.stream.cancelled",
      ])
      XCTAssertEqual(audit.events.map(\.reasonCode), ["stream.operation-prestart-denied"])
      XCTAssertEqual(emissions.failureCodes, ["runtimeExecutionAuthorizationRevoked"])
      XCTAssertEqual(emissions.terminalCount, 1)
      XCTAssertEqual(emissions.waitForQuietPeriod(), .timedOut)
    }
  }

  func testCompletionBeforeExternalExecutionLeavesPlannedOperationRetryableAndAudited() throws {
    try withFixture { fixture in
      let audit = StreamSourceAuditRecorder()
      let emissions = InteractiveEmissionCollector()
      let task = CompletionBeforeExternalExecutionTask()
      let request = interactiveRequest(
        requestID: "completion-before-start",
        idempotencyKey: "completion-before-start-key"
      )
      let producer = try makeInteractiveProducer(
        fixture: fixture,
        request: request,
        audit: audit,
        prepareTask: { task },
        sink: emissions.receive
      )

      producer.start()
      XCTAssertEqual(emissions.waitForTerminal(), .success)
      XCTAssertEqual(task.externalStartCount, 0)
      let record = try XCTUnwrap(
        try ControlRequestRepository(store: fixture.store).load(request.requestID!)
      )
      XCTAssertEqual(record.status, .accepted)
      let operationReference = interactiveOperationReference(
        subjectID: fixture.owner.binding.subject.identifier,
        requestID: request.requestID!
      )
      XCTAssertEqual(
        try fixture.store.operations.loadAll().first(where: { $0.id == operationReference })?.status,
        .planned
      )
      XCTAssertEqual(
        try ControlRequestRepository(store: fixture.store).beginStreamOperation(
          ControlRequestSubmission(
            request: record,
            idempotencyExpiresAt: "2027-08-03T00:00:00Z"
          ),
          operationReference: operationReference,
          plannedActionType: "stream.exec"
        ),
        .retryNeverStarted
      )
      XCTAssertEqual(audit.events.map(\.reasonCode), ["stream.operation-not-started"])
      XCTAssertEqual(emissions.failureCodes, ["runtimeExecutionNotStarted"])
      XCTAssertEqual(emissions.terminalCount, 1)
    }
  }

  func testSuccessfulPreparationRecordsStartedImmediatelyBeforeTaskStartAndCompletesDurably() throws {
    try withFixture { fixture in
      let enteredPreparation = DispatchSemaphore(value: 0)
      let releasePreparation = DispatchSemaphore(value: 0)
      let taskStarted = DispatchSemaphore(value: 0)
      let audit = StreamSourceAuditRecorder()
      let emissions = InteractiveEmissionCollector()
      let request = interactiveRequest(requestID: "prepare-success", idempotencyKey: "prepare-success-key")
      let operationReference = interactiveOperationReference(
        subjectID: fixture.owner.binding.subject.identifier,
        requestID: request.requestID!
      )
      let fakeTask = SuccessfulPreparationTask {
        let repository = ControlRequestRepository(store: fixture.store)
        XCTAssertEqual(try? repository.load(request.requestID!)?.status, .accepted)
        XCTAssertEqual(
          try? fixture.store.operations.loadAll().first(where: { $0.id == operationReference })?.status,
          .recorded
        )
        let stages = ((try? fixture.store.events.streamPage(after: nil, pageSize: 100).events) ?? [])
          .map { $0.event.type }
          .filter { $0.hasPrefix("operation.stream.") }
        XCTAssertEqual(stages, ["operation.stream.planned", "operation.stream.started"])
        XCTAssertEqual(audit.events.map(\.reasonCode), ["stream.operation-started"])
        taskStarted.signal()
      }
      let producer = try makeInteractiveProducer(
        fixture: fixture,
        request: request,
        audit: audit,
        prepareTask: {
          enteredPreparation.signal()
          _ = releasePreparation.wait(timeout: .now() + 5)
          return fakeTask
        },
        sink: emissions.receive
      )

      producer.start()
      XCTAssertEqual(enteredPreparation.wait(timeout: .now() + 1), .success)
      XCTAssertEqual(
        try? fixture.store.operations.loadAll().first(where: { $0.id == operationReference })?.status,
        .planned
      )
      XCTAssertTrue(audit.events.isEmpty)

      releasePreparation.signal()
      XCTAssertEqual(taskStarted.wait(timeout: .now() + 1), .success)
      XCTAssertEqual(emissions.waitForTerminal(), .success)
      XCTAssertEqual(try? ControlRequestRepository(store: fixture.store).load(request.requestID!)?.status, .completed)
      XCTAssertEqual(
        try? fixture.store.operations.loadAll().first(where: { $0.id == operationReference })?.status,
        .succeeded
      )
      let terminalStages = ((try? fixture.store.events.streamPage(after: nil, pageSize: 100).events) ?? [])
        .map { $0.event.type }
        .filter { $0.hasPrefix("operation.stream.") }
      XCTAssertEqual(terminalStages, [
        "operation.stream.planned", "operation.stream.started", "operation.stream.completed",
      ])
      XCTAssertEqual(audit.events.map(\.reasonCode), [
        "stream.operation-started", "stream.operation-completed",
      ])
      XCTAssertEqual(emissions.failureCodes, [])
      XCTAssertEqual(emissions.terminalCount, 1)
    }
  }

  private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-daemon-control-streams-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
    let owner = peer(subjectID: "owner", codeHash: String(repeating: "a", count: 40))
    try ControlIdentityRepository(store: store).bootstrap(ControlPeerIdentityRecord(
      subjectID: owner.binding.subject.identifier,
      userID: UInt32(owner.binding.subject.userID),
      codeIdentity: owner.binding.peer.codeIdentity,
      declaredBySubjectID: owner.binding.subject.identifier,
      declaredAt: "2026-08-03T00:00:00Z",
      updatedAt: "2026-08-03T00:00:00Z"
    ))
    let manifest = root.appendingPathComponent("hostwright.yaml")
    try Data(
      """
      version: 3
      project: stream-tests
      services:
        api:
          image: ghcr.io/example/api:latest
          resources:
            requests: {cpus: 1, memory: 512MiB}
            limits: {cpus: 1, memory: 512MiB}
      """.utf8
    ).write(to: manifest)
    let validatedManifest = try ManifestValidator.validated(
      String(contentsOf: manifest, encoding: .utf8)
    )
    try store.desiredStates.saveManifestSnapshot(
      projectID: "project-stream-tests",
      manifestPath: manifest.path,
      manifestHash: String(repeating: "a", count: 64),
      desiredGeneration: 1,
      manifest: validatedManifest,
      timestamp: "2026-08-03T00:00:00Z",
      mutationProvider: "apple-container-cli",
      projectResourceUUID: "11111111-1111-4111-8111-111111111111"
    )
    let cursorCodec = try ControlStreamCursorCodec(
      keyStore: InMemoryAuditSigningKeyStore(),
      now: { Date(timeIntervalSince1970: 1_754_252_800) }
    )
    try body(Fixture(
      store: store,
      cursorCodec: cursorCodec,
      factory: DaemonControlStreamSourceFactory(
        store: store,
        cursorCodec: cursorCodec,
        manifestPath: manifest.path,
        stateDatabasePath: store.path,
        auditRecorder: TamperEvidentAuditTrail(
          store: store,
          keyStore: InMemoryAuditSigningKeyStore()
        )
      ),
      owner: owner,
      operatorPeer: peer(subjectID: "operator", codeHash: String(repeating: "b", count: 40))
    ))
  }

  private func interactiveRequest(requestID: String, idempotencyKey: String) -> ControlStreamOpenRequest {
    ControlStreamOpenRequest(
      source: .exec,
      target: "22222222-2222-4222-8222-222222222222",
      filter: .object([
        "serviceName": .string("api"),
        "arguments": .array([.string("/usr/bin/true")]),
      ]),
      requestID: requestID,
      idempotencyKey: idempotencyKey
    )
  }

  private func followingLogsRequest(follow: Bool) -> ControlStreamOpenRequest {
    var fields: [String: ControlPlaneJSONValue] = [
      "serviceName": .string("api"),
      "tail": .integer(25),
    ]
    if follow {
      fields["follow"] = .bool(true)
      fields["timeoutSeconds"] = .integer(300)
    }
    return ControlStreamOpenRequest(
      source: .logs,
      target: "22222222-2222-4222-8222-222222222222",
      filter: .object(fields)
    )
  }

  private func streamOwnership() -> OwnershipRecord {
    OwnershipRecord(
      id: "ownership-api",
      resourceIdentifier: "hostwright-stream-tests-api",
      resourceType: "container",
      projectID: "project-stream-tests",
      serviceName: "api",
      runtimeAdapter: "apple-container-cli",
      createdAt: "2026-08-03T00:00:00Z",
      observedAt: "2026-08-03T00:00:00Z",
      cleanupEligible: true,
      metadataJSONRedacted: "{}",
      resourceUUID: "22222222-2222-4222-8222-222222222222",
      projectResourceUUID: "11111111-1111-4111-8111-111111111111",
      fencingToken: "33333333-3333-4333-8333-333333333333"
    )
  }

  private func makeInteractiveProducer(
    fixture: Fixture,
    request: ControlStreamOpenRequest,
    audit: StreamSourceAuditRecorder,
    prepare: @escaping @Sendable () -> Void,
    preStartAuthorization: @escaping @Sendable () throws -> Void = {},
    sink: @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  ) throws -> InteractiveControlStreamProducer {
    let binding = try binding(for: fixture.owner, request: request)
    let requestID = try XCTUnwrap(request.requestID)
    let idempotencyKey = try XCTUnwrap(request.idempotencyKey)
    let operationReference = interactiveOperationReference(
      subjectID: fixture.owner.binding.subject.identifier,
      requestID: requestID
    )
    let timestamp = "2026-08-03T00:00:00Z"
    let disposition = try ControlRequestRepository(store: fixture.store).beginStreamOperation(
      ControlRequestSubmission(
        request: ControlRequestRecord(
          requestID: requestID,
          subjectID: fixture.owner.binding.subject.identifier,
          idempotencyKey: idempotencyKey,
          requestDigestSHA256: String(repeating: "a", count: 64),
          status: .accepted,
          operationReference: operationReference,
          createdAt: timestamp,
          updatedAt: timestamp
        ),
        idempotencyExpiresAt: "2027-08-03T00:00:00Z"
      ),
      operationReference: operationReference,
      plannedActionType: "stream.exec"
    )
    XCTAssertEqual(disposition, .created)
    return try InteractiveControlStreamProducer(
      cursorCodec: fixture.cursorCodec,
      binding: binding,
      request: request,
      sourceCursor: nil,
      manifestPath: "/nonexistent/unused-by-test.yaml",
      stateDatabasePath: fixture.store.path,
      requestRepository: ControlRequestRepository(store: fixture.store),
      auditRecorder: audit,
      subjectID: fixture.owner.binding.subject.identifier,
      preStartAuthorization: preStartAuthorization,
      prepareTaskOverride: {
        prepare()
        throw InteractivePreparationTestError.releasedAfterCancellation
      },
      sink: sink
    )
  }

  private func makeInteractiveProducer(
    fixture: Fixture,
    request: ControlStreamOpenRequest,
    audit: StreamSourceAuditRecorder,
    prepareTask: @escaping @Sendable () throws -> any DaemonInteractiveStreamTask,
    preStartAuthorization: @escaping @Sendable () throws -> Void = {},
    sink: @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  ) throws -> InteractiveControlStreamProducer {
    let binding = try binding(for: fixture.owner, request: request)
    let requestID = try XCTUnwrap(request.requestID)
    let idempotencyKey = try XCTUnwrap(request.idempotencyKey)
    let operationReference = interactiveOperationReference(
      subjectID: fixture.owner.binding.subject.identifier,
      requestID: requestID
    )
    let timestamp = "2026-08-03T00:00:00Z"
    let disposition = try ControlRequestRepository(store: fixture.store).beginStreamOperation(
      ControlRequestSubmission(
        request: ControlRequestRecord(
          requestID: requestID,
          subjectID: fixture.owner.binding.subject.identifier,
          idempotencyKey: idempotencyKey,
          requestDigestSHA256: String(repeating: "a", count: 64),
          status: .accepted,
          operationReference: operationReference,
          createdAt: timestamp,
          updatedAt: timestamp
        ),
        idempotencyExpiresAt: "2027-08-03T00:00:00Z"
      ),
      operationReference: operationReference,
      plannedActionType: "stream.exec"
    )
    XCTAssertEqual(disposition, .created)
    return try InteractiveControlStreamProducer(
      cursorCodec: fixture.cursorCodec,
      binding: binding,
      request: request,
      sourceCursor: nil,
      manifestPath: "/nonexistent/unused-by-test.yaml",
      stateDatabasePath: fixture.store.path,
      requestRepository: ControlRequestRepository(store: fixture.store),
      auditRecorder: audit,
      subjectID: fixture.owner.binding.subject.identifier,
      preStartAuthorization: preStartAuthorization,
      prepareTaskOverride: prepareTask,
      sink: sink
    )
  }

  private func assertCancelledBeforeStartEvidence(
    fixture: Fixture,
    request: ControlStreamOpenRequest,
    audit: StreamSourceAuditRecorder,
    emissions: InteractiveEmissionCollector
  ) {
    let requestID = request.requestID!
    let operationReference = interactiveOperationReference(
      subjectID: fixture.owner.binding.subject.identifier,
      requestID: requestID
    )
    XCTAssertEqual(try? ControlRequestRepository(store: fixture.store).load(requestID)?.status, .error)
    XCTAssertEqual(
      try? fixture.store.operations.loadAll().first(where: { $0.id == operationReference })?.status,
      .abandoned
    )
    let operationStages = ((try? fixture.store.events.streamPage(after: nil, pageSize: 100).events) ?? [])
      .map { $0.event.type }
      .filter { $0.hasPrefix("operation.stream.") }
    XCTAssertEqual(operationStages, [
      "operation.stream.planned", "operation.stream.cancel-requested", "operation.stream.cancelled",
    ])
    XCTAssertEqual(audit.events.map(\.reasonCode), [
      "stream.operation-cancel-requested", "stream.operation-cancelled",
    ])
    XCTAssertEqual(emissions.failureCodes, ["runtimeExecutionCancelledBeforeStart"])
  }

  private func interactiveOperationReference(subjectID: String, requestID: String) -> String {
    "stream:" + SHA256.hash(data: Data("\(subjectID):\(requestID)".utf8))
      .prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  private func event(
    _ id: String,
    timestamp: String = "2026-08-03T00:00:00Z",
    severity: StateEventSeverity = .info,
    type: String = "state.changed",
    source: String = "hostwrightd",
    projectID: String? = nil,
    payload: String = "{}"
  ) -> EventRecord {
    EventRecord(
      id: id,
      timestamp: timestamp,
      severity: severity,
      type: type,
      source: source,
      projectID: projectID,
      serviceName: nil,
      runtimeAdapter: nil,
      message: id,
      payloadJSONRedacted: payload
    )
  }

  private func binding(
    for peer: AuthenticatedControlPeer,
    request: ControlStreamOpenRequest
  ) throws -> ControlStreamCursorBinding {
    try ControlStreamCursorBinding(
      subjectID: peer.binding.subject.identifier,
      source: request.source,
      target: request.target,
      filter: request.filter
    )
  }

  private func peer(subjectID: String, codeHash: String) -> AuthenticatedControlPeer {
    AuthenticatedControlPeer(
      binding: ControlSessionBinding(
        sessionID: "session-\(subjectID)",
        daemonGeneration: 1,
        serverNonce: "nonce-\(subjectID)",
        socketDevice: 1,
        socketInode: 2,
        peer: UnixPeerIdentity(
          effectiveUID: 501,
          effectiveGID: 20,
          pid: 123,
          pidVersion: 1,
          auditSessionID: 1,
          codeIdentity: CodeIdentity(
            teamIdentifier: "993YC3JY4Q",
            signingIdentifier: "hostwright-test",
            codeDirectoryHash: codeHash,
            validationMode: .installedRequirement
          )
        ),
        subject: LocalSubject(identifier: subjectID, userID: 501, codeIdentityHash: codeHash)
      )
    )
  }

  private struct Fixture {
    let store: SQLiteStateStore
    let cursorCodec: ControlStreamCursorCodec
    let factory: DaemonControlStreamSourceFactory
    let owner: AuthenticatedControlPeer
    let operatorPeer: AuthenticatedControlPeer
  }
}

private final class EmissionCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private let expectedDataCount: Int?
  private let expectedGapCount: Int?
  private let terminateWhenSatisfied: Bool
  private var didSignal = false
  private var emissions: [ControlStreamEmission] = []

  init(
    dataCount: Int? = nil,
    gapCount: Int? = nil,
    terminateWhenSatisfied: Bool = false
  ) {
    expectedDataCount = dataCount
    expectedGapCount = gapCount
    self.terminateWhenSatisfied = terminateWhenSatisfied
  }

  func receive(_ emission: ControlStreamEmission) -> ControlStreamEmissionDisposition {
    lock.lock()
    emissions.append(emission)
    let satisfied = isSatisfied
    if satisfied && !didSignal {
      didSignal = true
      semaphore.signal()
    }
    lock.unlock()
    return satisfied && terminateWhenSatisfied ? .terminated : .accepted
  }

  func wait() -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 2)
  }

  var dataCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return emissions.reduce(into: 0) { count, emission in
      if case .data = emission { count += 1 }
    }
  }

  var dataIDs: [String] {
    lock.lock()
    defer { lock.unlock() }
    return emissions.compactMap { emission in
      guard case .data(_, let payload) = emission,
        case .object(let fields) = payload,
        case .string(let id)? = fields["id"]
      else { return nil }
      return id
    }
  }

  var dataCursors: [String] {
    lock.lock()
    defer { lock.unlock() }
    return emissions.compactMap { emission in
      guard case .data(let cursor, _) = emission else { return nil }
      return cursor
    }
  }

  var gaps: [ControlStreamGap] {
    lock.lock()
    defer { lock.unlock() }
    return emissions.compactMap { emission in
      guard case .gap(_, let payload) = emission else { return nil }
      return payload
    }
  }

  var gapCursors: [String] {
    lock.lock()
    defer { lock.unlock() }
    return emissions.compactMap { emission in
      guard case .gap(let cursor, _) = emission else { return nil }
      return cursor
    }
  }

  var failures: [SanitizedError] {
    lock.lock()
    defer { lock.unlock() }
    return emissions.compactMap { emission in
      guard case .failure(let error) = emission else { return nil }
      return error
    }
  }

  private var isSatisfied: Bool {
    let data = emissions.reduce(into: 0) { count, emission in
      if case .data = emission { count += 1 }
    }
    let gaps = emissions.reduce(into: 0) { count, emission in
      if case .gap = emission { count += 1 }
    }
    let failed = emissions.contains { emission in
      if case .failure = emission { return true }
      return false
    }
    return failed
      || (expectedDataCount.map { data >= $0 } ?? false)
      || (expectedGapCount.map { gaps >= $0 } ?? false)
  }
}

private final class CreditRecoveryCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let blocked = DispatchSemaphore(value: 0)
  private let recovered = DispatchSemaphore(value: 0)
  private var firstDataWasBlocked = false
  private var events: [ControlStreamEmission] = []

  func receive(_ emission: ControlStreamEmission) -> ControlStreamEmissionDisposition {
    lock.lock()
    defer { lock.unlock() }
    if case .data = emission, !firstDataWasBlocked {
      firstDataWasBlocked = true
      blocked.signal()
      return .creditExhausted
    }
    events.append(emission)
    if case .data = emission { recovered.signal() }
    return .accepted
  }

  func waitForBlockedData() -> DispatchTimeoutResult {
    blocked.wait(timeout: .now() + 2)
  }

  func waitForRecoveredData() -> DispatchTimeoutResult {
    recovered.wait(timeout: .now() + 2)
  }

  var dataIDs: [String] {
    lock.lock()
    defer { lock.unlock() }
    return events.compactMap { emission in
      guard case .data(_, let payload) = emission,
        case .object(let fields) = payload,
        case .string(let id)? = fields["id"]
      else { return nil }
      return id
    }
  }

  var heartbeatCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return events.reduce(into: 0) { count, emission in
      if case .heartbeat = emission { count += 1 }
    }
  }
}

private enum InteractivePreparationTestError: Error {
  case releasedAfterCancellation
}

private final class SuccessfulPreparationTask: DaemonInteractiveStreamTask, @unchecked Sendable {
  private let onStart: @Sendable () -> Void

  init(onStart: @escaping @Sendable () -> Void) {
    self.onStart = onStart
  }

  func start(
    beforeExternalExecution: @escaping @Sendable () throws -> Void,
    sink _: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void,
    completion: @escaping @Sendable (Result<RuntimeInteractiveExecutionResult, Error>) -> Void
  ) throws {
    try beforeExternalExecution()
    onStart()
    completion(.success(RuntimeInteractiveExecutionResult(
      operation: .exec,
      exitStatus: 0,
      emittedFrameCount: 0,
      standardErrorTail: ""
    )))
  }

  func cancel() {}
  func sendInput(_ data: Data, onConsumed: @escaping @Sendable () -> Void) -> Bool { false }
  func finishInput() {}
  func resize(columns: UInt16, rows: UInt16) -> Bool { false }
  func forward(signal: Int32) -> Bool { false }
}

private enum PreStartAuthorizationTestError: Error {
  case revoked
}

private final class PreStartAuthorizationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var revoked = false

  func revoke() {
    lock.lock()
    revoked = true
    lock.unlock()
  }

  func authorize() throws {
    lock.lock()
    let isRevoked = revoked
    lock.unlock()
    if isRevoked { throw PreStartAuthorizationTestError.revoked }
  }
}

private final class PreStartRevocationTask: DaemonInteractiveStreamTask, @unchecked Sendable {
  private let lock = NSLock()
  private var starts = 0
  private var cancellations = 0

  var startCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return starts
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellations
  }

  func start(
    beforeExternalExecution: @escaping @Sendable () throws -> Void,
    sink _: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void,
    completion _: @escaping @Sendable (Result<RuntimeInteractiveExecutionResult, Error>) -> Void
  ) throws {
    try beforeExternalExecution()
    lock.lock()
    starts += 1
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancellations += 1
    lock.unlock()
  }

  func sendInput(_ data: Data, onConsumed: @escaping @Sendable () -> Void) -> Bool { false }
  func finishInput() {}
  func resize(columns: UInt16, rows: UInt16) -> Bool { false }
  func forward(signal: Int32) -> Bool { false }
}

private final class CancellableFollowingLogsTask: DaemonInteractiveStreamTask, @unchecked Sendable {
  private let started = DispatchSemaphore(value: 0)
  private let cancelled = DispatchSemaphore(value: 0)

  func waitForStart() -> DispatchTimeoutResult {
    started.wait(timeout: .now() + 1)
  }

  func waitForCancellation() -> DispatchTimeoutResult {
    cancelled.wait(timeout: .now() + 1)
  }

  func start(
    beforeExternalExecution: @escaping @Sendable () throws -> Void,
    sink _: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void,
    completion _: @escaping @Sendable (Result<RuntimeInteractiveExecutionResult, Error>) -> Void
  ) throws {
    try beforeExternalExecution()
    started.signal()
  }

  func cancel() { cancelled.signal() }
  func sendInput(_: Data, onConsumed _: @escaping @Sendable () -> Void) -> Bool { false }
  func finishInput() {}
  func resize(columns _: UInt16, rows _: UInt16) -> Bool { false }
  func forward(signal _: Int32) -> Bool { false }
}

private enum CompletionBeforeExternalExecutionTaskError: Error {
  case failedBeforeStart
}

private final class CompletionBeforeExternalExecutionTask: DaemonInteractiveStreamTask, @unchecked Sendable {
  private let lock = NSLock()
  private var externalStarts = 0

  var externalStartCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return externalStarts
  }

  func start(
    beforeExternalExecution _: @escaping @Sendable () throws -> Void,
    sink _: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void,
    completion: @escaping @Sendable (Result<RuntimeInteractiveExecutionResult, Error>) -> Void
  ) throws {
    completion(.failure(CompletionBeforeExternalExecutionTaskError.failedBeforeStart))
  }

  func cancel() {}
  func sendInput(_ data: Data, onConsumed: @escaping @Sendable () -> Void) -> Bool { false }
  func finishInput() {}
  func resize(columns: UInt16, rows: UInt16) -> Bool { false }
  func forward(signal: Int32) -> Bool { false }
}

private final class InteractiveEmissionCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let terminal = DispatchSemaphore(value: 0)
  private var emissions: [ControlStreamEmission] = []
  private var signalledTerminal = false

  func receive(_ emission: ControlStreamEmission) -> ControlStreamEmissionDisposition {
    lock.lock()
    emissions.append(emission)
    if !signalledTerminal, isTerminal(emission) {
      signalledTerminal = true
      terminal.signal()
    }
    lock.unlock()
    return .accepted
  }

  func waitForTerminal() -> DispatchTimeoutResult {
    terminal.wait(timeout: .now() + 1)
  }

  func waitForQuietPeriod() -> DispatchTimeoutResult {
    terminal.wait(timeout: .now() + 0.2)
  }

  var terminalCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return emissions.filter(isTerminal).count
  }

  var failureCodes: [String] {
    lock.lock()
    defer { lock.unlock() }
    return emissions.compactMap { emission in
      guard case .failure(let error) = emission else { return nil }
      return error.code
    }
  }

  private func isTerminal(_ emission: ControlStreamEmission) -> Bool {
    switch emission {
    case .end, .failure: return true
    case .data, .heartbeat, .gap: return false
    }
  }
}

private final class StreamSourceAuditRecorder: ControlSecurityAuditRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var records: [String: AuditRecord] = [:]
  private var capturedEvents: [ControlSecurityAuditEvent] = []

  @discardableResult
  func record(_ event: ControlSecurityAuditEvent) throws -> AuditRecord {
    try event.validate()
    lock.lock()
    defer { lock.unlock() }
    if let existing = records[event.deduplicationKey] { return existing }
    let sequence = UInt64(capturedEvents.count + 1)
    let record = AuditRecord(
      identifier: "stream-source-audit-\(sequence)",
      segmentID: "test-segment",
      sequence: sequence,
      timestamp: Date(timeIntervalSince1970: 1_754_252_800),
      previousDigest: nil,
      subjectID: event.subjectID,
      requestID: event.requestID,
      target: event.target,
      action: event.action,
      outcome: event.outcome,
      reasonCode: event.reasonCode,
      operationRef: event.operationRef,
      payloadDigest: event.payloadDigest,
      recordDigest: "sha256:" + String(repeating: "a", count: 64),
      signingKeyID: "test-key"
    )
    records[event.deduplicationKey] = record
    capturedEvents.append(event)
    return record
  }

  var events: [ControlSecurityAuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return capturedEvents
  }
}

import Foundation
import XCTest

@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane

final class SchedulerCLIParityTests: XCTestCase {
    func testAllSchedulerRoutesUsePersistentUnaryControlOperations() throws {
        for action in SchedulerCLIAction.allCases {
            let route = try CLIControlRoute.classify(arguments: [
                "scheduler", action.rawValue, "--stdin", "--output", "json",
            ])
            XCTAssertEqual(route.transport, .persistentControlAPI)
            XCTAssertEqual(route.execution, .unary)
            XCTAssertEqual(route.operation, "scheduler.\(action.rawValue)")
            XCTAssertEqual(route.subcommand, action.rawValue)
            XCTAssertEqual(route.mutating, action == .apply)
            XCTAssertEqual(route.output, .json)
        }
    }

    func testPlanRequestUsesCurrentRevisionAndCanonicalJSONOutput() throws {
        let bodyData = Data(
            "{\"projectID\":\"project-a\",\"input\":{\"nodes\":[],\"pendingWorkloads\":[]}}".utf8
        )
        let capture = RequestCapture()
        let environment = makeEnvironment(
            capture: capture,
            requestFile: bodyData,
            response: .object([
                "decision": .object(["kind": .string("plan")]),
                "inputDigest": .string(String(repeating: "a", count: 64)),
            ])
        )

        let result = HostwrightCommandRunner.run(arguments: [
            "scheduler", "plan", "--request", "scheduler.json", "--json",
        ], environment: environment)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertEqual(
            result.standardOutput,
            "{\"decision\":{\"kind\":\"plan\"},\"inputDigest\":\"\(String(repeating: "a", count: 64))\"}\n"
        )
        XCTAssertEqual(capture.request?.operation, "scheduler.plan")
        XCTAssertEqual(capture.request?.protocolRevision, .current)
        XCTAssertNil(capture.request?.idempotencyKey)
        XCTAssertEqual(capture.filePath, "/client/project/scheduler.json")
        XCTAssertEqual(capture.request?.body, try ControlPlaneJSONValue.decode(bodyData))
    }

    func testApplyReadsStandardInputUsesCurrentRevisionAndIsMutating() throws {
        let decisionID = "11111111-1111-4111-8111-111111111111"
        let workloadID = "22222222-2222-4222-8222-222222222222"
        let digest = String(repeating: "b", count: 64)
        let bodyData = Data(
            "{\"decisionID\":\"\(decisionID)\",\"expectedInputDigest\":\"\(digest)\",\"projectID\":\"project-a\",\"workloadID\":\"\(workloadID)\"}".utf8
        )
        let capture = RequestCapture()
        let environment = makeEnvironment(
            capture: capture,
            standardInput: bodyData,
            response: .object(["status": .string("fenced")])
        )

        let result = HostwrightCommandRunner.run(arguments: [
            "scheduler", "apply", "--stdin", "--output", "text",
        ], environment: environment)

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("Scheduler operation: scheduler.apply"))
        XCTAssertTrue(result.standardOutput.contains("\"status\":\"fenced\""))
        XCTAssertEqual(capture.request?.operation, "scheduler.apply")
        XCTAssertEqual(capture.request?.protocolRevision, .current)
        XCTAssertEqual(capture.request?.idempotencyKey, "scheduler-request")
        XCTAssertEqual(capture.request?.body, try ControlPlaneJSONValue.decode(bodyData))
        XCTAssertEqual(capture.standardInputReads, 1)
        XCTAssertEqual(capture.fileReads, 0)
    }

    func testStatusAndExplainForwardStrictDecisionReferences() throws {
        let decisionID = "11111111-1111-4111-8111-111111111111"
        let bodyData = Data(
            "{\"decisionID\":\"\(decisionID)\",\"projectID\":\"project-a\"}".utf8
        )
        for action in [SchedulerCLIAction.status, .explain] {
            let capture = RequestCapture()
            let environment = makeEnvironment(
                capture: capture,
                requestFile: bodyData,
                response: .object([
                    "decisionID": .string(decisionID),
                    "status": .string("committed"),
                ])
            )
            let result = HostwrightCommandRunner.run(
                arguments: [
                    "scheduler", action.rawValue, "--request", "decision.json", "--json",
                ],
                environment: environment
            )

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertEqual(capture.request?.operation, "scheduler.\(action.rawValue)")
            XCTAssertEqual(capture.request?.protocolRevision, .current)
            XCTAssertEqual(capture.request?.body, try ControlPlaneJSONValue.decode(bodyData))
        }
    }

    func testDuplicateAndOversizedInputFailBeforePersistentDispatch() {
        let duplicate = Data(
            "{\"projectID\":\"project-a\",\"input\":{\"nodes\":[],\"nodes\":[],\"pendingWorkloads\":[]}}".utf8
        )
        let duplicateCapture = RequestCapture()
        let duplicateResult = HostwrightCommandRunner.run(
            arguments: ["scheduler", "plan", "--stdin", "--json"],
            environment: makeEnvironment(capture: duplicateCapture, standardInput: duplicate)
        )
        XCTAssertNotEqual(duplicateResult.exitCode, 0)
        XCTAssertTrue(duplicateResult.standardError.contains("HW-API-001"))
        XCTAssertNil(duplicateCapture.request)

        let oversizedCapture = RequestCapture()
        let oversizedResult = HostwrightCommandRunner.run(
            arguments: ["scheduler", "simulate", "--stdin", "--json"],
            environment: makeEnvironment(
                capture: oversizedCapture,
                standardInput: Data(
                    repeating: 120,
                    count: SchedulerControlWireContract.maximumInputBytes + 1
                )
            )
        )
        XCTAssertNotEqual(oversizedResult.exitCode, 0)
        XCTAssertTrue(oversizedResult.standardError.contains("HW-API-001"))
        XCTAssertNil(oversizedCapture.request)
    }

    func testMalformedUnknownAndWrongShapeBodiesFailBeforePersistentDispatch() {
        let invalidBodies: [(SchedulerCLIAction, Data)] = [
            (.plan, Data("{".utf8)),
            (
                .plan,
                Data(
                    "{\"projectID\":\"project-a\",\"input\":{\"nodes\":[],\"pendingWorkloads\":[],\"unknown\":true}}".utf8
                )
            ),
            (
                .plan,
                Data("{\"projectID\":\"project-a\",\"input\":{\"nodes\":[]}}".utf8)
            ),
            (
                .status,
                Data(
                    "{\"projectID\":\"project-a\",\"decisionID\":\"11111111-1111-4111-8111-111111111111\",\"extra\":true}".utf8
                )
            ),
            (
                .apply,
                Data(
                    "{\"decisionID\":\"11111111-1111-4111-8111-111111111111\",\"expectedInputDigest\":\"not-a-digest\",\"projectID\":\"project-a\",\"workloadID\":\"22222222-2222-4222-8222-222222222222\"}".utf8
                )
            )
        ]

        for (action, body) in invalidBodies {
            let capture = RequestCapture()
            let result = HostwrightCommandRunner.run(
                arguments: ["scheduler", action.rawValue, "--stdin", "--json"],
                environment: makeEnvironment(
                    capture: capture,
                    standardInput: body
                )
            )

            XCTAssertNotEqual(result.exitCode, 0, action.rawValue)
            XCTAssertTrue(result.standardError.contains("HW-API-001"), action.rawValue)
            XCTAssertNil(capture.request, action.rawValue)
        }
    }

    func testPreviousRevisionIsRejectedForSchedulerOperations() {
        for action in SchedulerCLIAction.allCases {
            let operation = "scheduler.\(action.rawValue)"
            XCTAssertFalse(
                ControlProtocolCompatibility.acceptsRequest(
                    operation: operation,
                    revision: .previous
                )
            )
            XCTAssertTrue(
                ControlProtocolCompatibility.acceptsRequest(
                    operation: operation,
                    revision: .current
                )
            )
        }
    }

    func testUnavailableApplyResponseFailsClosedWithoutLocalFallback() {
        let capture = RequestCapture()
        let result = HostwrightCommandRunner.run(
            arguments: ["scheduler", "apply", "--stdin", "--json"],
            environment: makeEnvironment(
                capture: capture,
                standardInput: Data(
                    "{\"decisionID\":\"11111111-1111-4111-8111-111111111111\",\"expectedInputDigest\":\"\(String(repeating: "b", count: 64))\",\"projectID\":\"project-a\",\"workloadID\":\"22222222-2222-4222-8222-222222222222\"}".utf8
                ),
                responseStatus: .rejected,
                responseReasonCode: .unsupportedOperation,
                responseError: SanitizedError(
                    code: "schedulerAuthorityUnavailable",
                    message: "The scheduler operation was rejected safely."
                )
            )
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.isEmpty)
        XCTAssertTrue(result.standardError.contains("rejected safely"))
        XCTAssertTrue(result.standardError.contains("scheduler"))
        XCTAssertNotNil(capture.request)
    }

    private func makeEnvironment(
        capture: RequestCapture,
        requestFile: Data = Data(),
        standardInput: Data = Data(),
        response: ControlPlaneJSONValue = .object(["ok": .bool(true)]),
        responseStatus: ControlResponseStatus = .completed,
        responseReasonCode: ControlReasonCode = .completed,
        responseError: SanitizedError? = nil
    ) -> HostwrightCommandTransportEnvironment {
        HostwrightCommandTransportEnvironment(
            socketPath: { "/tmp/hostwright-scheduler.sock" },
            persistentSend: { _, request in
                capture.record(request: request)
                return ControlResponseEnvelope(
                    protocolRevision: .current,
                    requestID: request.requestID,
                    status: responseStatus,
                    reasonCode: responseReasonCode,
                    result: responseStatus == .completed ? response : nil,
                    error: responseError
                )
            },
            bootstrapSend: { _ in
                XCTFail("Scheduler commands must not use bootstrap control.")
                throw TestError.unexpectedTransport
            },
            streamRun: { _, _, _ in
                XCTFail("Scheduler commands must not use streaming control.")
                throw TestError.unexpectedTransport
            },
            requestID: { "scheduler-request" },
            workingDirectory: { "/client/project" },
            readRequestFile: { path, maximumBytes in
                capture.recordFileRead(path: path, maximumBytes: maximumBytes)
                return requestFile
            },
            readStandardInput: { maximumBytes in
                capture.recordStandardInputRead(maximumBytes: maximumBytes)
                return standardInput
            }
        )
    }
}

private enum TestError: Error {
    case unexpectedTransport
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var request: ControlRequestEnvelope?
    private(set) var fileReads = 0
    private(set) var standardInputReads = 0
    private(set) var filePath: String?

    func record(request: ControlRequestEnvelope) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func recordFileRead(path: String, maximumBytes: Int) {
        lock.lock()
        fileReads += 1
        filePath = path
        lock.unlock()
        XCTAssertEqual(maximumBytes, SchedulerControlWireContract.maximumInputBytes)
    }

    func recordStandardInputRead(maximumBytes: Int) {
        lock.lock()
        standardInputReads += 1
        lock.unlock()
        XCTAssertEqual(maximumBytes, SchedulerControlWireContract.maximumInputBytes)
    }
}

private extension ControlPlaneJSONValue {
    static func decode(_ data: Data) throws -> ControlPlaneJSONValue {
        try JSONDecoder().decode(ControlPlaneJSONValue.self, from: data)
    }
}

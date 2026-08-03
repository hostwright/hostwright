import Foundation
import XCTest
@testable import HostwrightCommandTransport
import HostwrightControlPlane
import HostwrightRuntime

final class CLIControlStreamPayloadTests: XCTestCase {
    func testRuntimeEnvelopeUsesTheStrictBoundedRuntimeContract() throws {
        let envelope = try RuntimeStreamEnvelope(
            sequence: 1,
            stream: .standardOutput,
            payload: Data("hello".utf8)
        )
        let value = try controlValue(envelope)
        XCTAssertEqual(try CLIControlStreamClient.runtimeEnvelope(value), envelope)

        guard case .object(var fields) = value else {
            return XCTFail("Expected a runtime envelope object.")
        }
        fields["unexpected"] = .bool(true)
        XCTAssertThrowsError(
            try CLIControlStreamClient.runtimeEnvelope(.object(fields))
        )
        fields.removeValue(forKey: "unexpected")
        fields["schemaVersion"] = .integer(2)
        XCTAssertThrowsError(
            try CLIControlStreamClient.runtimeEnvelope(.object(fields))
        )
        fields["schemaVersion"] = .integer(1)
        fields["payloadBase64"] = .string("not-canonical-base64")
        XCTAssertThrowsError(
            try CLIControlStreamClient.runtimeEnvelope(.object(fields))
        )
    }

    func testEventAndLogPayloadsRejectUnknownAndNoncanonicalFields() throws {
        let event: ControlPlaneJSONValue = .object([
            "eventReference": .string("event:1"),
            "id": .string("event-1"),
            "message": .string("safe"),
            "operationReferences": .array([]),
            "payloadJSONRedacted": .string("{}"),
            "position": .integer(1),
            "projectID": .string("project-demo"),
            "runtimeAdapter": .null,
            "serviceName": .string("api"),
            "severity": .string("info"),
            "source": .string("hostwrightd"),
            "timestamp": .string("2026-08-03T00:00:00Z"),
            "type": .string("state.changed"),
        ])
        XCTAssertEqual(try CLIControlStreamClient.eventRecord(event).position, 1)
        guard case .object(var eventFields) = event else {
            return XCTFail("Expected an event object.")
        }
        eventFields["secret"] = .string("must-not-pass")
        XCTAssertThrowsError(
            try CLIControlStreamClient.eventRecord(.object(eventFields))
        )

        let bytes = Data([0, 1, 2, 3])
        let log: ControlPlaneJSONValue = .object([
            "encoding": .string("base64"),
            "ordinal": .integer(0),
            "payload": .string(bytes.base64EncodedString()),
        ])
        XCTAssertEqual(try CLIControlStreamClient.logPayload(log), bytes)
        XCTAssertThrowsError(try CLIControlStreamClient.logPayload(.object([
            "encoding": .string("base64"),
            "ordinal": .integer(0),
            "payload": .string("AA"),
        ])))
        XCTAssertThrowsError(try CLIControlStreamClient.logPayload(.object([
            "encoding": .string("base64"),
            "ordinal": .integer(0),
            "payload": .string(bytes.base64EncodedString()),
            "unexpected": .null,
        ])))
        XCTAssertThrowsError(try CLIControlStreamClient.logPayload(.object([
            "encoding": .string("base64"),
            "ordinal": .integer(-1),
            "payload": .string(bytes.base64EncodedString()),
        ])))
    }

    func testPreparationResponseStrictlyRejectsUnknownFields() throws {
        let preparation = try CLIControlStreamPreparation(
            source: .events,
            target: nil,
            filter: nil,
            cursor: nil,
            timeoutMilliseconds: 1_000,
            output: .json
        )
        let value = try controlValue(preparation)
        let response = ControlResponseEnvelope(
            requestID: "prepare-1",
            status: .completed,
            reasonCode: .completed,
            result: value
        )
        XCTAssertEqual(try CLIControlStreamPreparation.decode(response), preparation)

        guard case .object(var fields) = value else {
            return XCTFail("Expected a preparation object.")
        }
        fields["unexpected"] = .string("rejected")
        XCTAssertThrowsError(try CLIControlStreamPreparation.decode(
            ControlResponseEnvelope(
                requestID: "prepare-2",
                status: .completed,
                reasonCode: .completed,
                result: .object(fields)
            )
        ))
    }

    private func controlValue<T: Encodable>(_ value: T) throws -> ControlPlaneJSONValue {
        try JSONDecoder().decode(
            ControlPlaneJSONValue.self,
            from: JSONEncoder().encode(value)
        )
    }
}

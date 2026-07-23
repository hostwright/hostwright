import Foundation
import XCTest
@testable import HostwrightRuntime

final class ContainerizationHelperProtocolTests: XCTestCase {
    private struct Payload: Codable, Equatable, Sendable {
        let name: String
        let count: Int
    }

    private let digest = String(repeating: "a", count: 64)
    private let requestID = UUID(uuidString: "01234567-89ab-cdef-8123-456789abcdef")!

    func testOperationContractIsExact() {
        XCTAssertEqual(
            ContainerizationHelperOperation.allCases.map(\.rawValue),
            [
                "negotiate", "observe", "localImageEvidence", "resourceUsage", "logs",
                "create", "start", "stop", "restart", "delete", "cancel", "shutdown"
            ]
        )
    }

    func testRequestRoundTripsAsCanonicalJSONWithTypedPayloadAndMutationContext() throws {
        let mutationContext = RuntimeMutationContext(
            providerID: .appleContainerization,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "operation-1",
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 2,
            projectResourceUUID: "22222222-2222-4222-8222-222222222222",
            projectGeneration: 3,
            providerGeneration: 4,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
        let request = makeRequest(mutationContext: mutationContext)

        let data = try ContainerizationHelperCanonicalJSON.encode(request)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix(#"{"capabilityDigest":"#))
        XCTAssertTrue(text.contains(#""deadline":2000"#))
        XCTAssertTrue(text.contains(#""requestID":"01234567-89ab-cdef-8123-456789abcdef""#))
        XCTAssertEqual(
            try ContainerizationHelperCanonicalJSON.decodeRequest(Payload.self, from: data),
            request
        )
    }

    func testCanonicalDecoderRejectsWhitespaceUnknownAndDuplicateFields() throws {
        let canonical = try ContainerizationHelperCanonicalJSON.encode(makeRequest())
        XCTAssertThrowsError(
            try ContainerizationHelperCanonicalJSON.decodeRequest(
                Payload.self,
                from: Data(" \(String(decoding: canonical, as: UTF8.self))".utf8)
            )
        ) { XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .nonCanonicalJSON) }

        let text = String(decoding: canonical, as: UTF8.self)
        let duplicate = text.replacingOccurrences(
            of: #""protocolVersion":1"#,
            with: #""protocolVersion":1,"protocolVersion":1"#
        )
        XCTAssertThrowsError(
            try ContainerizationHelperCanonicalJSON.decodeRequest(Payload.self, from: Data(duplicate.utf8))
        )

        let unknown = text.dropLast() + #", "unknown":true}"#
        XCTAssertThrowsError(
            try ContainerizationHelperCanonicalJSON.decodeRequest(Payload.self, from: Data(unknown.utf8))
        )
    }

    func testResultAndErrorEnvelopesAreVersionedTypedAndRedacted() throws {
        let result = ContainerizationHelperResultEnvelope(
            requestID: requestID,
            operation: .observe,
            result: Payload(name: "ok", count: 1)
        )
        let resultData = try ContainerizationHelperCanonicalJSON.encode(result)
        XCTAssertEqual(
            try ContainerizationHelperCanonicalJSON.decodeResult(Payload.self, from: resultData),
            result
        )

        let failure = ContainerizationHelperErrorEnvelope(
            requestID: requestID,
            operation: .create,
            error: ContainerizationHelperErrorPayload(
                code: .executionFailed,
                message: "authorization=secret-token"
            )
        )
        let errorData = try ContainerizationHelperCanonicalJSON.encode(failure)
        XCTAssertFalse(String(decoding: errorData, as: UTF8.self).contains("secret-token"))
        XCTAssertEqual(try ContainerizationHelperCanonicalJSON.decodeError(from: errorData), failure)
    }

    func testCanonicalDecoderRejectsProtocolMismatch() throws {
        let request = ContainerizationHelperRequest(
            protocolVersion: 2,
            requestID: requestID,
            operation: .observe,
            deadlineUnixMilliseconds: 2_000,
            capabilityDigest: digest,
            idempotencyKey: "request-1",
            payload: Payload(name: "demo", count: 1)
        )
        let data = try ContainerizationHelperCanonicalJSON.encode(request)
        XCTAssertThrowsError(
            try ContainerizationHelperCanonicalJSON.decodeRequest(Payload.self, from: data)
        ) { XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .unsupportedProtocolVersion(2)) }
    }

    func testFrameUsesFourByteBigEndianLength() throws {
        let payload = Data("hello".utf8)
        let frame = try ContainerizationHelperFraming.frame(payload)
        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 0, 5])
        XCTAssertEqual(try ContainerizationHelperFraming.decodeSingleFrame(frame), payload)
    }

    func testIncrementalDecoderAcceptsSplitHeaderAndPayload() throws {
        let frame = try ContainerizationHelperFraming.frame(Data("hello".utf8))
        var decoder = ContainerizationHelperFrameDecoder()

        XCTAssertNil(try decoder.append(frame.prefix(2)))
        XCTAssertNil(try decoder.append(frame.dropFirst(2).prefix(3)))
        XCTAssertEqual(try decoder.append(frame.dropFirst(5)), Data("hello".utf8))
        XCTAssertEqual(try decoder.finish(), Data("hello".utf8))
    }

    func testFrameDecoderRejectsZeroOverflowTruncationAndTrailingBytes() throws {
        XCTAssertThrowsError(try ContainerizationHelperFraming.decodeSingleFrame(Data([0, 0, 0, 0]))) {
            XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .zeroLengthFrame)
        }
        XCTAssertThrowsError(try ContainerizationHelperFraming.decodeSingleFrame(Data([0, 128, 0, 1]))) {
            XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .frameTooLarge)
        }
        XCTAssertThrowsError(try ContainerizationHelperFraming.decodeSingleFrame(Data([0, 0, 0, 2, 1]))) {
            XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .truncatedFrame)
        }
        XCTAssertThrowsError(try ContainerizationHelperFraming.decodeSingleFrame(Data([0, 0, 0, 1, 1, 2]))) {
            XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .trailingFrameBytes)
        }
    }

    func testFrameBoundIsExactlyEightMiB() throws {
        let maximum = Data(repeating: 0x61, count: ContainerizationHelperProtocolV1.maximumPayloadBytes)
        XCTAssertEqual(try ContainerizationHelperFraming.frame(maximum).count, maximum.count + 4)
        XCTAssertThrowsError(try ContainerizationHelperFraming.frame(maximum + Data([0x61]))) {
            XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .frameTooLarge)
        }
    }

    func testRequestValidatorRejectsReplayExpiredAndInvalidBindings() throws {
        var validator = ContainerizationHelperRequestValidator(expectedCapabilityDigest: digest)
        let request = makeRequest()
        XCTAssertNoThrow(try validator.validate(request, nowUnixMilliseconds: 1_000))
        XCTAssertThrowsError(try validator.validate(request, nowUnixMilliseconds: 1_000)) {
            XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .duplicateRequestID)
        }

        var fresh = ContainerizationHelperRequestValidator(expectedCapabilityDigest: digest)
        XCTAssertThrowsError(try fresh.validate(request, nowUnixMilliseconds: 2_000)) {
            XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .expiredDeadline)
        }

        let badDigest = ContainerizationHelperRequest(
            requestID: UUID(),
            operation: .observe,
            deadlineUnixMilliseconds: 2_001,
            capabilityDigest: "not-a-digest",
            idempotencyKey: "request-2",
            payload: Payload(name: "demo", count: 1)
        )
        XCTAssertThrowsError(try fresh.validate(badDigest, nowUnixMilliseconds: 1_000)) {
            XCTAssertEqual($0 as? ContainerizationHelperProtocolError, .invalidCapabilityDigest)
        }
    }

    func testPeerIdentityPolicyRequiresSameUIDPositivePIDExactTeamAndRequirement() throws {
        let policy = ContainerizationHelperPeerIdentityPolicy(expectedUserID: 501)
        let valid = ContainerizationHelperPeerIdentity(
            userID: 501,
            processID: 42,
            teamIdentifier: "993YC3JY4Q",
            designatedRequirement: ContainerizationHelperPeerIdentityPolicy.expectedDesignatedRequirement
        )
        XCTAssertNoThrow(try policy.validate(valid))

        let failures: [(ContainerizationHelperPeerIdentity, ContainerizationHelperPeerIdentityError)] = [
            (.init(userID: 502, processID: 42, teamIdentifier: valid.teamIdentifier, designatedRequirement: valid.designatedRequirement), .userIDMismatch),
            (.init(userID: 501, processID: 0, teamIdentifier: valid.teamIdentifier, designatedRequirement: valid.designatedRequirement), .invalidProcessID),
            (.init(userID: 501, processID: 42, teamIdentifier: "AAAAAAAAAA", designatedRequirement: valid.designatedRequirement), .teamIdentifierMismatch),
            (.init(userID: 501, processID: 42, teamIdentifier: valid.teamIdentifier, designatedRequirement: "anchor apple"), .designatedRequirementMismatch)
        ]
        for (identity, expectedError) in failures {
            XCTAssertThrowsError(try policy.validate(identity)) {
                XCTAssertEqual($0 as? ContainerizationHelperPeerIdentityError, expectedError)
            }
        }
    }

    private func makeRequest(
        mutationContext: RuntimeMutationContext? = nil
    ) -> ContainerizationHelperRequest<Payload> {
        ContainerizationHelperRequest(
            requestID: requestID,
            operation: .observe,
            deadlineUnixMilliseconds: 2_000,
            capabilityDigest: digest,
            mutationContext: mutationContext,
            idempotencyKey: "request-1",
            payload: Payload(name: "demo", count: 1)
        )
    }
}

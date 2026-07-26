import Foundation
import XCTest
@testable import HostwrightStorage

final class StorageProviderProtocolTests: XCTestCase {
    private struct Payload: Codable, Equatable, Sendable {
        let name: String
        let bytes: Data
    }

    private let digest = String(repeating: "a", count: 64)
    private let requestID = UUID(uuidString: "01234567-89ab-cdef-8123-456789abcdef")!

    func testCanonicalRequestAndResultRoundTrip() throws {
        let request = makeRequest(operation: .attach, mutationContext: context())
        let requestData = try StorageProviderCanonicalJSON.encodeRequest(request)
        XCTAssertEqual(
            try StorageProviderCanonicalJSON.decodeRequest(Payload.self, from: requestData),
            request
        )
        XCTAssertTrue(
            String(decoding: requestData, as: UTF8.self)
                .contains(#""requestID":"01234567-89ab-cdef-8123-456789abcdef""#)
        )

        let result = StorageProviderResultEnvelope(
            requestID: requestID,
            operation: .attach,
            result: Payload(name: "attached", bytes: Data())
        )
        let resultData = try StorageProviderCanonicalJSON.encodeResult(result)
        let decoded = try StorageProviderCanonicalJSON.decodeResult(
            Payload.self,
            from: resultData
        )
        XCTAssertEqual(decoded, result)
        XCTAssertNoThrow(
            try StorageProviderResponseValidator.validate(
                decoded,
                for: requestID,
                operation: .attach
            )
        )
    }

    func testCanonicalErrorRoundTripsWithTypedRetryAndRecovery() throws {
        let envelope = StorageProviderErrorEnvelope(
            requestID: requestID,
            operation: .restore,
            failure: StorageProviderFailure(
                category: .staleGeneration,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .reobserve,
                diagnostic: "The generation changed.",
                guidance: "Observe before retrying."
            )
        )

        let data = try StorageProviderCanonicalJSON.encodeError(envelope)
        XCTAssertTrue(
            String(decoding: data, as: UTF8.self)
                .contains(#""requestID":"01234567-89ab-cdef-8123-456789abcdef""#)
        )
        let decoded = try StorageProviderCanonicalJSON.decodeError(from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertNoThrow(
            try StorageProviderResponseValidator.validate(
                decoded,
                for: requestID,
                operation: .restore
            )
        )
    }

    func testCanonicalDecoderRejectsWhitespaceUnknownAndDuplicateFields() throws {
        let canonical = try StorageProviderCanonicalJSON.encodeRequest(makeRequest())
        XCTAssertThrowsError(
            try StorageProviderCanonicalJSON.decodeRequest(
                Payload.self,
                from: Data(" \(String(decoding: canonical, as: UTF8.self))".utf8)
            )
        ) {
            XCTAssertEqual($0 as? StorageProviderProtocolError, .nonCanonicalJSON)
        }

        let text = String(decoding: canonical, as: UTF8.self)
        let duplicate = text.replacingOccurrences(
            of: #""protocolVersion":1"#,
            with: #""protocolVersion":1,"protocolVersion":1"#
        )
        XCTAssertThrowsError(
            try StorageProviderCanonicalJSON.decodeRequest(
                Payload.self,
                from: Data(duplicate.utf8)
            )
        )

        let unknown = text.dropLast() + #","unknown":true}"#
        XCTAssertThrowsError(
            try StorageProviderCanonicalJSON.decodeRequest(
                Payload.self,
                from: Data(unknown.utf8)
            )
        )
    }

    func testWireBoundsRejectEmptyAndOverflow() throws {
        XCTAssertThrowsError(
            try StorageProviderCanonicalJSON.decodeRequest(
                Payload.self,
                from: Data()
            )
        ) {
            XCTAssertEqual($0 as? StorageProviderProtocolError, .emptyRequest)
        }
        XCTAssertThrowsError(
            try StorageProviderCanonicalJSON.decodeRequest(
                Payload.self,
                from: Data(
                    repeating: 0x61,
                    count: StorageProviderContract.maximumRequestBytes + 1
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .requestTooLarge(
                    maximumBytes: StorageProviderContract.maximumRequestBytes
                )
            )
        }
        XCTAssertThrowsError(
            try StorageProviderCanonicalJSON.decodeResult(
                Payload.self,
                from: Data(
                    repeating: 0x61,
                    count: StorageProviderContract.maximumResultBytes + 1
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .resultTooLarge(
                    maximumBytes: StorageProviderContract.maximumResultBytes
                )
            )
        }
    }

    func testRequestValidatorRejectsProtocolMismatchStaleCapabilityAndMissingContext() {
        var validator = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        XCTAssertThrowsError(
            try validator.validate(
                makeRequest(protocolVersion: 2),
                nowUnixMilliseconds: 1_000
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .unsupportedProtocolVersion(2)
            )
        }
        XCTAssertThrowsError(
            try validator.validate(
                makeRequest(capabilitySHA256: String(repeating: "b", count: 64)),
                nowUnixMilliseconds: 1_000
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .capabilityDigestMismatch
            )
        }
        XCTAssertThrowsError(
            try validator.validate(
                makeRequest(operation: .delete),
                nowUnixMilliseconds: 1_000
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .mutationContextRequired
            )
        }
    }

    func testRequestValidatorRejectsStaleGenerationsReplayAndCancellation() throws {
        let request = makeRequest(operation: .detach, mutationContext: context())
        var staleResource = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        XCTAssertThrowsError(
            try staleResource.validate(
                request,
                nowUnixMilliseconds: 1_000,
                expectedResourceGeneration: 3
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .staleResourceGeneration(expected: 3, actual: 2)
            )
        }

        var staleAttachment = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        XCTAssertThrowsError(
            try staleAttachment.validate(
                request,
                nowUnixMilliseconds: 1_000,
                expectedResourceGeneration: 2,
                expectedAttachmentGeneration: 5
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .staleAttachmentGeneration(expected: 5, actual: 4)
            )
        }

        var replay = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        try replay.validate(
            request,
            nowUnixMilliseconds: 1_000,
            expectedResourceGeneration: 2,
            expectedAttachmentGeneration: 4
        )
        XCTAssertThrowsError(
            try replay.validate(
                request,
                nowUnixMilliseconds: 1_000,
                expectedResourceGeneration: 2,
                expectedAttachmentGeneration: 4
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .duplicateRequestID
            )
        }

        var cancelled = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        XCTAssertThrowsError(
            try cancelled.validate(
                makeRequest(),
                nowUnixMilliseconds: 1_000,
                cancellationRequested: true
            )
        ) {
            XCTAssertEqual($0 as? StorageProviderProtocolError, .cancelled)
        }
    }

    func testReplayWindowFailsClosedAtItsMemoryBound() throws {
        var validator = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        for _ in 0..<StorageProviderContract.maximumRememberedRequestIDs {
            try validator.validate(
                makeRequest(requestID: UUID()),
                nowUnixMilliseconds: 1_000
            )
        }

        XCTAssertThrowsError(
            try validator.validate(
                makeRequest(requestID: UUID()),
                nowUnixMilliseconds: 1_000
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderProtocolError,
                .replayWindowExhausted
            )
        }
    }

    func testDeadlineIsPositiveFutureAndBounded() {
        var invalid = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        XCTAssertThrowsError(
            try invalid.validate(
                makeRequest(deadlineUnixMilliseconds: 0),
                nowUnixMilliseconds: 1_000
            )
        ) {
            XCTAssertEqual($0 as? StorageProviderProtocolError, .invalidDeadline)
        }

        var expired = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        XCTAssertThrowsError(
            try expired.validate(
                makeRequest(deadlineUnixMilliseconds: 1_000),
                nowUnixMilliseconds: 1_000
            )
        ) {
            XCTAssertEqual($0 as? StorageProviderProtocolError, .expiredDeadline)
        }

        var tooFar = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        XCTAssertThrowsError(
            try tooFar.validate(
                makeRequest(
                    deadlineUnixMilliseconds:
                        1_000 + StorageProviderContract.maximumDeadlineWindowMilliseconds + 1
                ),
                nowUnixMilliseconds: 1_000
            )
        ) {
            XCTAssertEqual($0 as? StorageProviderProtocolError, .deadlineTooFar)
        }

        var overflow = StorageProviderRequestValidator(
            expectedCapabilitySHA256: digest
        )
        XCTAssertThrowsError(
            try overflow.validate(
                makeRequest(deadlineUnixMilliseconds: Int64.max),
                nowUnixMilliseconds: -1
            )
        ) {
            XCTAssertEqual($0 as? StorageProviderProtocolError, .deadlineTooFar)
        }
    }

    func testResponseValidatorRejectsMismatchedRequestAndOperation() {
        let result = StorageProviderResultEnvelope(
            requestID: UUID(),
            operation: .observe,
            result: Payload(name: "observed", bytes: Data())
        )
        XCTAssertThrowsError(
            try StorageProviderResponseValidator.validate(
                result,
                for: requestID,
                operation: .observe
            )
        ) {
            XCTAssertEqual($0 as? StorageProviderProtocolError, .responseMismatch)
        }
        XCTAssertThrowsError(
            try StorageProviderResponseValidator.validate(
                StorageProviderResultEnvelope(
                    requestID: requestID,
                    operation: .health,
                    result: Payload(name: "healthy", bytes: Data())
                ),
                for: requestID,
                operation: .observe
            )
        ) {
            XCTAssertEqual($0 as? StorageProviderProtocolError, .responseMismatch)
        }
    }

    func testTransportTerminationMapsHangOverflowAndAmbiguityFailClosed() {
        let hung = StorageProviderFailureNormalizer.normalize(
            .hung,
            operation: .attach
        )
        XCTAssertEqual(hung.category, .timedOut)
        XCTAssertEqual(hung.retryDisposition, .safeAfterObservation)
        XCTAssertEqual(hung.recoveryDisposition, .reobserve)
        XCTAssertTrue(hung.requiresObservationBeforeRetry)

        let overflow = StorageProviderFailureNormalizer.normalize(
            .outputOverflow,
            operation: .observe
        )
        XCTAssertEqual(overflow.category, .outputLimited)
        XCTAssertEqual(overflow.retryDisposition, .safeAfterObservation)

        let ambiguous = StorageProviderFailureNormalizer.normalize(
            .ambiguousEffect,
            operation: .delete
        )
        XCTAssertEqual(ambiguous.category, .ambiguousEffect)
        XCTAssertEqual(ambiguous.retryDisposition, .resumeFromCheckpoint)
        XCTAssertEqual(ambiguous.recoveryDisposition, .safeHold)
    }

    func testProtocolErrorsNormalizeWithStableRetrySemantics() {
        let stale = StorageProviderFailureNormalizer.normalize(
            .staleResourceGeneration(expected: 3, actual: 2)
        )
        XCTAssertEqual(stale.category, .staleGeneration)
        XCTAssertEqual(stale.retryDisposition, .safeAfterObservation)
        XCTAssertEqual(stale.recoveryDisposition, .reobserve)

        let replay = StorageProviderFailureNormalizer.normalize(
            .duplicateRequestID
        )
        XCTAssertEqual(replay.category, .replayedRequest)
        XCTAssertEqual(replay.retryDisposition, .never)
        XCTAssertEqual(replay.recoveryDisposition, .safeHold)

        let mismatch = StorageProviderFailureNormalizer.normalize(
            .capabilityDigestMismatch
        )
        XCTAssertEqual(mismatch.category, .incompatible)
        XCTAssertEqual(mismatch.retryDisposition, .never)
        XCTAssertEqual(mismatch.recoveryDisposition, .reobserve)
    }

    private func makeRequest(
        requestID: UUID? = nil,
        protocolVersion: Int = StorageProviderContract.protocolVersion,
        operation: StorageProviderOperation = .observe,
        deadlineUnixMilliseconds: Int64 = 2_000,
        capabilitySHA256: String? = nil,
        mutationContext: StorageProviderMutationContext? = nil
    ) -> StorageProviderRequest<Payload> {
        StorageProviderRequest(
            protocolVersion: protocolVersion,
            requestID: requestID ?? self.requestID,
            operation: operation,
            deadlineUnixMilliseconds: deadlineUnixMilliseconds,
            capabilitySHA256: capabilitySHA256 ?? digest,
            idempotencyKey: "request-1",
            mutationContext: mutationContext,
            payload: Payload(name: "demo", bytes: Data([0, 1, 2]))
        )
    }

    private func context() -> StorageProviderMutationContext {
        StorageProviderMutationContext(
            projectUUID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            projectGeneration: 3,
            resourceUUID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            resourceGeneration: 2,
            attachmentGeneration: 4,
            fencingToken: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        )
    }
}

import CryptoKit
import Foundation
import XCTest
@testable import HostwrightAccelerator

final class AcceleratorPlatformAdapterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_754_000_000)
    private let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let workloadID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testMetalInjectedReaderPreservesMeasuredAllocationAndCallerTime() throws {
        let reading = try AcceleratorMetalAllocationObservation(
            deviceName: "Test Metal Device",
            registryID: 42,
            currentAllocatedBytes: 12_345,
            recommendedMaxWorkingSetBytes: 987_654,
            observedGeneration: 7,
            observedAt: now,
            isRemovable: false,
            hasUnifiedMemory: true
        )
        let observation = try AcceleratorMetalAllocationAdapter(
            reader: FixedMetalReader(observation: reading)
        ).read(observedAt: now, observedGeneration: 7)

        XCTAssertEqual(observation.currentAllocatedBytes, 12_345)
        XCTAssertEqual(observation.recommendedMaxWorkingSetBytes, 987_654)
        XCTAssertEqual(observation.observedAt, now)
        XCTAssertEqual(observation.observedGeneration, 7)
        XCTAssertEqual(observation.source, .metalCurrentAllocatedSize)
        XCTAssertTrue(observation.hasUnifiedMemory)

        let object = try jsonObject(observation)
        XCTAssertNil(object["freeCapacityBytes"])
        XCTAssertNil(object["quotaBytes"])
        XCTAssertNil(object["reservedBytes"])

        let decoded = try decode(
            AcceleratorMetalAllocationObservation.self,
            from: object
        )
        XCTAssertEqual(decoded, observation)
    }

    func testMetalAdapterRejectsInvalidIdentityAndGeneration() throws {
        XCTAssertThrowsError(
            try AcceleratorMetalAllocationObservation(
                deviceName: "Device",
                registryID: 0,
                currentAllocatedBytes: 1,
                recommendedMaxWorkingSetBytes: nil,
                observedGeneration: 1,
                observedAt: now
            )
        ) { error in
            XCTAssertEqual(
                error as? AcceleratorPlatformAdapterError,
                .invalidObservation("metal.allocation")
            )
        }

        XCTAssertThrowsError(
            try AcceleratorMetalAllocationObservation(
                deviceName: String(
                    repeating: "x",
                    count: AcceleratorPlatformAdapterLimits.maxDeviceNameBytes + 1
                ),
                registryID: 1,
                currentAllocatedBytes: 1,
                recommendedMaxWorkingSetBytes: nil,
                observedGeneration: 1,
                observedAt: now
            )
        )

        let observation = try AcceleratorMetalAllocationObservation(
            deviceName: "Device",
            registryID: 1,
            currentAllocatedBytes: 0,
            recommendedMaxWorkingSetBytes: nil,
            observedGeneration: 1,
            observedAt: now
        )
        XCTAssertThrowsError(
            try AcceleratorMetalAllocationAdapter(
                reader: FixedMetalReader(observation: observation)
            ).read(observedAt: now, observedGeneration: 0)
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .invalidObservation("observedGeneration"))
        }
    }

    func testMetalNestedUnknownKeysAreRejected() throws {
        let observation = try AcceleratorMetalAllocationObservation(
            deviceName: "Device",
            registryID: 9,
            currentAllocatedBytes: 1,
            recommendedMaxWorkingSetBytes: nil,
            observedGeneration: 1,
            observedAt: now
        )
        var object = try jsonObject(observation)
        object["freeCapacityBytes"] = 1

        XCTAssertThrowsError(
            try decode(AcceleratorMetalAllocationObservation.self, from: object)
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .invalidValue("metal.observation"))
        }
    }

    func testCoreMLInjectedReaderReportsPolicyOnlyEvidence() throws {
        let digest = try fixedDigest("a")
        let evidence = try AcceleratorCoreMLEligibilityObservation(
            requestedComputeUnits: "all",
            modelHash: digest,
            status: .policyAccepted,
            explanation: .computeUnitsArePolicyOnly,
            source: .coreMLComputeUnitsPolicy,
            observedGeneration: 4,
            observedAt: now
        )
        let adapterEvidence = try AcceleratorCoreMLEligibilityAdapter(
            reader: FixedCoreMLReader(observation: evidence)
        ).read(
            requestedComputeUnits: "all",
            modelHash: digest,
            observedAt: now,
            observedGeneration: 4
        )

        XCTAssertEqual(adapterEvidence.status, .policyAccepted)
        XCTAssertEqual(adapterEvidence.explanation, .computeUnitsArePolicyOnly)
        XCTAssertEqual(adapterEvidence.source, .coreMLComputeUnitsPolicy)
        let object = try jsonObject(adapterEvidence)
        XCTAssertNil(object["headroomBytes"])
        XCTAssertNil(object["coreCount"])
        XCTAssertNil(object["availableComputeUnits"])
        XCTAssertEqual(
            try decode(AcceleratorCoreMLEligibilityObservation.self, from: object),
            adapterEvidence
        )
    }

    func testCoreMLInconsistentReaderEvidenceFailsClosed() throws {
        let digest = try fixedDigest("a")
        let inconsistent = try AcceleratorCoreMLEligibilityObservation(
            requestedComputeUnits: "all",
            modelHash: digest,
            status: .policyAccepted,
            explanation: .computeUnitsArePolicyOnly,
            source: .coreMLComputeUnitsPolicy,
            observedGeneration: 1,
            observedAt: now
        )

        XCTAssertThrowsError(
            try AcceleratorCoreMLEligibilityAdapter(
                reader: FixedCoreMLReader(observation: inconsistent)
            ).read(
                requestedComputeUnits: "cpu-only",
                modelHash: digest,
                observedAt: now,
                observedGeneration: 1
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .invalidObservation("core-ml"))
        }
    }

    func testCoreMLUnavailableEvidenceIsExplicit() throws {
        let unavailable = try AcceleratorCoreMLEligibilityObservation(
            requestedComputeUnits: "cpu-and-gpu",
            status: .unavailable,
            explanation: .coreMLFrameworkUnavailable,
            source: .contractBoundary,
            observedGeneration: 2,
            observedAt: now
        )
        let result = try AcceleratorCoreMLEligibilityAdapter(
            reader: FixedCoreMLReader(observation: unavailable)
        ).read(
            requestedComputeUnits: "cpu-and-gpu",
            modelHash: nil,
            observedAt: now,
            observedGeneration: 2
        )
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertNotEqual(result.status, .policyAccepted)
    }

    func testCoreMLUnknownKeysAndInconsistentSourceAreRejected() throws {
        let evidence = try AcceleratorCoreMLEligibilityObservation(
            requestedComputeUnits: "cpu-only",
            status: .policyAccepted,
            explanation: .computeUnitsArePolicyOnly,
            source: .coreMLComputeUnitsPolicy,
            observedGeneration: 1,
            observedAt: now
        )
        var object = try jsonObject(evidence)
        object["headroomBytes"] = 1
        XCTAssertThrowsError(
            try decode(AcceleratorCoreMLEligibilityObservation.self, from: object)
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .invalidValue("coreML.observation"))
        }

        XCTAssertThrowsError(
            try AcceleratorCoreMLEligibilityObservation(
                requestedComputeUnits: "cpu-only",
                status: .policyAccepted,
                explanation: .computeUnitsArePolicyOnly,
                source: .contractBoundary,
                observedGeneration: 1,
                observedAt: now
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .invalidValue("policyEvidence"))
        }
    }

    func testMLXRequestBindsModeInputDigestAndLimits() throws {
        let input = Data([1, 2, 3, 4])
        let request = try makeExecutionRequest(input: input)
        let mlxRequest = try AcceleratorMLXExecutionRequest(
            executionRequest: request,
            input: input
        )
        XCTAssertEqual(mlxRequest.input, input)

        XCTAssertThrowsError(
            try AcceleratorMLXExecutionRequest(
                executionRequest: request,
                input: Data([4, 3, 2, 1])
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .inputDigestMismatch("input"))
        }

        XCTAssertThrowsError(
            try AcceleratorMLXExecutionRequest(
                executionRequest: try makeExecutionRequest(
                    input: input,
                    mode: .metal
                ),
                input: input
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .invalidMode("executionRequest.mode"))
        }
    }

    func testDefaultMLXAdapterReturnsUnsupportedWithoutExecutionClaim() async throws {
        let input = Data([1, 2, 3])
        let request = try AcceleratorMLXExecutionRequest(
            executionRequest: try makeExecutionRequest(input: input),
            input: input
        )
        let result = try await AcceleratorMLXExecutionAdapter().execute(
            request,
            observedAt: now.addingTimeInterval(1)
        )

        XCTAssertEqual(result, .unavailable("mlx-swift-backend-not-configured"))
        try result.validate()
        let decoded = try JSONDecoder().decode(
            AcceleratorMLXExecutionResult.self,
            from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(decoded, result)
    }

    func testMLXAdapterUsesInjectedExecutorOnlyForDeterministicTestEvidence() async throws {
        let input = Data([8, 7, 6])
        let request = try AcceleratorMLXExecutionRequest(
            executionRequest: try makeExecutionRequest(input: input),
            input: input
        )
        let result = try await AcceleratorMLXExecutionAdapter(
            executor: FixedMLXExecutor(result: .unsupported("test-backend"))
        ).execute(request, observedAt: now.addingTimeInterval(2))

        XCTAssertEqual(result, .unsupported("test-backend"))
        try result.validate()
    }

    func testMLXStrictDecoderRejectsUnknownAndOversizedDetails() throws {
        var object: [String: Any] = [
            "kind": "unsupported",
            "detail": "test-backend",
            "unexpected": true
        ]
        XCTAssertThrowsError(
            try decode(AcceleratorMLXExecutionResult.self, from: object)
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .invalidValue("mlx.result"))
        }

        object = [
            "kind": "unsupported",
            "detail": String(
                repeating: "x",
                count: AcceleratorPlatformAdapterLimits.maxDetailBytes + 1
            )
        ]
        XCTAssertThrowsError(
            try decode(AcceleratorMLXExecutionResult.self, from: object)
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .payloadTooLarge("mlx.result.detail"))
        }
    }

    func testLinuxGuestPassthroughIsBlockedBeforeAnyAdapter() throws {
        XCTAssertThrowsError(
            try AcceleratorGuestExecutionGuard.validate(
                .linuxGuestGPUPassthrough,
                isGuest: true
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .linuxGuestPassthroughBlocked)
        }
        XCTAssertThrowsError(
            try AcceleratorGuestExecutionGuard.validate(
                .linuxGuestANEPassthrough,
                isGuest: false
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorPlatformAdapterError,
                           .linuxGuestPassthroughBlocked)
        }
        XCTAssertNoThrow(
            try AcceleratorGuestExecutionGuard.validate(.metal, isGuest: true)
        )
    }

    private func makeExecutionRequest(
        input: Data,
        mode: AcceleratorExecutionMode = .mlxSwift
    ) throws -> AcceleratorExecutionRequest {
        let now = self.now
        let auth = try AcceleratorAuthenticationContext(
            subjectID: "subject-owner",
            sessionID: "session-1",
            authenticationDigest: try fixedDigest("b"),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        return try AcceleratorExecutionRequest(
            requestID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            grantID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            reservationID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            mode: mode,
            modelHash: try fixedDigest("a"),
            inputDigest: try digestData(input),
            inputBytes: input.count,
            outputLimitBytes: 1_024,
            timeoutMilliseconds: 5_000,
            budget: try AcceleratorBudgetVector(
                memoryBytes: 1_024,
                computeUnits: 10,
                concurrencyUnits: 1
            ),
            fence: try AcceleratorFence(nodeEpoch: 1, reservationSequence: 1),
            authentication: auth,
            requestedAt: now.addingTimeInterval(1)
        )
    }

    private func fixedDigest(_ character: Character) throws -> AcceleratorDigest {
        try AcceleratorDigest(String(repeating: character, count: 64))
    }

    private func digestData(_ value: Data) throws -> AcceleratorDigest {
        try AcceleratorDigest(
            SHA256.hash(data: value)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(value)
            ) as? [String: Any]
        )
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from object: [String: Any]
    ) throws -> T {
        try JSONDecoder().decode(
            type,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}

private struct FixedMetalReader: AcceleratorMetalAllocationReader {
    let observation: AcceleratorMetalAllocationObservation

    func readMetalAllocation(
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorMetalAllocationObservation {
        try AcceleratorMetalAllocationObservation(
            deviceName: observation.deviceName,
            registryID: observation.registryID,
            currentAllocatedBytes: observation.currentAllocatedBytes,
            recommendedMaxWorkingSetBytes: observation.recommendedMaxWorkingSetBytes,
            observedGeneration: observedGeneration,
            observedAt: observedAt,
            isRemovable: observation.isRemovable,
            hasUnifiedMemory: observation.hasUnifiedMemory,
            contractVersion: observation.contractVersion
        )
    }
}

private struct FixedCoreMLReader: AcceleratorCoreMLEligibilityReader {
    let observation: AcceleratorCoreMLEligibilityObservation

    func readCoreMLEligibility(
        requestedComputeUnits: String,
        modelHash: AcceleratorDigest?,
        observedAt: Date,
        observedGeneration: Int64
    ) throws -> AcceleratorCoreMLEligibilityObservation {
        guard observation.requestedComputeUnits == requestedComputeUnits,
              observation.modelHash == modelHash else {
            throw AcceleratorPlatformAdapterError.invalidObservation("core-ml")
        }
        return try AcceleratorCoreMLEligibilityObservation(
            requestedComputeUnits: observation.requestedComputeUnits,
            modelHash: observation.modelHash,
            status: observation.status,
            explanation: observation.explanation,
            source: observation.source,
            observedGeneration: observedGeneration,
            observedAt: observedAt,
            contractVersion: observation.contractVersion
        )
    }
}

private struct FixedMLXExecutor: AcceleratorMLXExecutor {
    let result: AcceleratorMLXExecutionResult

    func execute(
        _ request: AcceleratorMLXExecutionRequest
    ) async throws -> AcceleratorMLXExecutionResult {
        result
    }
}

import Foundation
import XCTest
@testable import HostwrightRuntime

final class RuntimeImageLifecycleTests: XCTestCase {
    private let operationID = "8c5783ca-7940-4481-9a20-a7ce97302557"
    private let idempotencyKey = String(repeating: "a", count: 64)
    private let capabilitySHA256 = String(repeating: "b", count: 64)

    func testDigestLockBindsRequestedReferencePlatformAndProviderEvidence() throws {
        let descriptor = "sha256:\(digestBody("c"))"
        let variant = "sha256:\(digestBody("d"))"
        let lock = try RuntimeImageDigestLock(
            requestedReference: "registry.example/team/app:stable",
            resolvedReference:
                "registry.example/team/app@\(descriptor)",
            descriptorDigest: descriptor,
            variantDigest: variant,
            operatingSystem: "linux",
            architecture: "arm64",
            providerID: .appleContainerCLI,
            capabilitySHA256: capabilitySHA256
        )

        XCTAssertEqual(lock.schemaVersion, 1)
        XCTAssertEqual(
            lock.resolvedReference,
            "registry.example/team/app@\(descriptor)"
        )
        XCTAssertNoThrow(
            try lock.verify(
                RuntimeLocalImageEvidence(
                    reference: lock.resolvedReference,
                    descriptorDigest: descriptor,
                    variantDigest: variant,
                    architecture: "arm64",
                    operatingSystem: "linux"
                ),
                providerID: .appleContainerCLI,
                capabilitySHA256: capabilitySHA256
            )
        )
        XCTAssertEqual(
            lock,
            try JSONDecoder().decode(
                RuntimeImageDigestLock.self,
                from: JSONEncoder().encode(lock)
            )
        )
    }

    func testDigestLockRejectsAliasPlatformProviderAndCapabilityDrift() throws {
        let descriptor = "sha256:\(digestBody("c"))"
        let variant = "sha256:\(digestBody("d"))"
        let lock = try RuntimeImageDigestLock.resolve(
            requestedReference: "registry.example:5000/team/app:stable",
            evidence: RuntimeLocalImageEvidence(
                reference: "registry.example:5000/team/app:stable",
                descriptorDigest: descriptor,
                variantDigest: variant,
                architecture: "arm64",
                operatingSystem: "linux"
            ),
            providerID: .appleContainerCLI,
            capabilitySHA256: capabilitySHA256
        )

        XCTAssertEqual(
            lock.resolvedReference,
            "registry.example:5000/team/app@\(descriptor)"
        )
        for evidence in [
            RuntimeLocalImageEvidence(
                reference: lock.resolvedReference,
                descriptorDigest: "sha256:\(digestBody("e"))",
                variantDigest: variant,
                architecture: "arm64",
                operatingSystem: "linux"
            ),
            RuntimeLocalImageEvidence(
                reference: lock.resolvedReference,
                descriptorDigest: descriptor,
                variantDigest: variant,
                architecture: "amd64",
                operatingSystem: "linux"
            )
        ] {
            XCTAssertThrowsError(
                try lock.verify(
                    evidence,
                    providerID: .appleContainerCLI,
                    capabilitySHA256: capabilitySHA256
                )
            )
        }
        XCTAssertThrowsError(
            try lock.verify(
                RuntimeLocalImageEvidence(
                    reference: lock.resolvedReference,
                    descriptorDigest: descriptor,
                    variantDigest: variant,
                    architecture: "arm64",
                    operatingSystem: "linux"
                ),
                providerID: .appleContainerization,
                capabilitySHA256: capabilitySHA256
            )
        )
        XCTAssertThrowsError(
            try lock.verify(
                RuntimeLocalImageEvidence(
                    reference: lock.resolvedReference,
                    descriptorDigest: descriptor,
                    variantDigest: variant,
                    architecture: "arm64",
                    operatingSystem: "linux"
                ),
                providerID: .appleContainerCLI,
                capabilitySHA256: String(repeating: "f", count: 64)
            )
        )
    }

    func testEveryOperationHasOneStrictValidRequestShape() throws {
        let requests = try [
            makeRequest(operation: .pull, source: "registry.example/app:v1"),
            makeRequest(
                operation: .build,
                target: "registry.example/app:v2",
                contextPath: "/private/tmp/context",
                dockerfilePath: "/private/tmp/context/Containerfile",
                platformOS: "linux",
                platformArchitecture: "arm64",
                offline: true,
                noCache: true
            ),
            makeRequest(
                operation: .push,
                source: "registry.example/app:v1",
                target: "registry.example/app:v1"
            ),
            makeRequest(operation: .tag, source: "app:v1", target: "app:stable"),
            makeRequest(
                operation: .load,
                source: "app:loaded",
                archivePath: "/private/tmp/image.oci"
            ),
            makeRequest(
                operation: .save,
                source: "app:v1",
                archivePath: "/private/tmp/image.oci"
            ),
            makeRequest(operation: .inspect, source: "app:v1"),
            makeRequest(operation: .delete, source: "app:v1"),
            makeRequest(operation: .prune, source: "app:old")
        ]

        XCTAssertEqual(requests.map(\.operation), RuntimeImageLifecycleOperation.allCases)
        XCTAssertTrue(requests.allSatisfy { (try? $0.planSHA256().count) == 64 })
    }

    func testOperationSpecificFieldsFailClosed() {
        assertThrows(
            .missingField(operation: .pull, field: "sourceReferences[1...1]")
        ) {
            _ = try self.makeRequest(operation: .pull)
        }
        assertThrows(
            .unexpectedField(operation: .inspect, field: "offline")
        ) {
            _ = try self.makeRequest(operation: .inspect, source: "app:v1", offline: true)
        }
        assertThrows(
            .unexpectedField(operation: .inspect, field: "platform")
        ) {
            _ = try self.makeRequest(
                operation: .inspect,
                source: "app:v1",
                platformOS: "linux",
                platformArchitecture: "arm64"
            )
        }
        XCTAssertNoThrow(try self.makeRequest(operation: .delete))
        XCTAssertNoThrow(try self.makeRequest(operation: .prune))
    }

    func testIdentityDigestPlatformPathAndOutputBoundsFailClosed() {
        XCTAssertThrowsError(
            try makeRequest(operation: .inspect, operationID: "operation-1", source: "app:v1")
        )
        XCTAssertThrowsError(
            try makeRequest(
                operation: .inspect,
                idempotencyKey: String(repeating: "A", count: 64),
                source: "app:v1"
            )
        )
        XCTAssertThrowsError(
            try makeRequest(
                operation: .inspect,
                capabilitySHA256: "sha256:\(capabilitySHA256)",
                source: "app:v1"
            )
        )
        XCTAssertThrowsError(
            try makeRequest(
                operation: .build,
                target: "app:v1",
                contextPath: "/private/tmp/../etc"
            )
        )
        XCTAssertThrowsError(
            try makeRequest(
                operation: .build,
                target: "app:v1",
                contextPath: "/private/tmp/context",
                dockerfilePath: "/private/other/Containerfile"
            )
        )
        XCTAssertThrowsError(
            try makeRequest(
                operation: .build,
                target: "app:v1",
                contextPath: "/private/tmp/context",
                platformOS: "linux"
            )
        )
        XCTAssertThrowsError(
            try makeRequest(
                operation: .build,
                target: "app:v1",
                contextPath: "/private/tmp/context",
                platformOS: "darwin",
                platformArchitecture: "arm64"
            )
        )
        XCTAssertThrowsError(
            try makeRequest(
                operation: .inspect,
                source: "app:v1",
                maximumOutputBytes: RuntimeImageLifecycleLimits.maximumOutputBytes + 1
            )
        )
    }

    func testReferencesRejectOptionsControlCharactersAndEmbeddedCredentials() {
        for reference in [
            "-delete-everything",
            " app:v1",
            "app:v1\nnext",
            "https://user:password@example.invalid/app:v1",
            "https://example.invalid/app:v1",
            "app name:v1",
            "app//name:v1",
            "registry..example/app:v1",
            "registry.example:99999/app:v1",
            "äpp:v1"
        ] {
            XCTAssertThrowsError(
                try makeRequest(operation: .inspect, source: reference),
                "accepted unsafe reference \(reference.debugDescription)"
            )
        }
        XCTAssertNoThrow(
            try makeRequest(
                operation: .inspect,
                source: "registry.example/app@sha256:\(digestBody("c"))"
            )
        )
    }

    func testSourceReferenceCardinalityAndOrderingAreExact() throws {
        let inspect = try makeRequest(
            operation: .inspect,
            sources: ["example/app:z", "example/app:a"]
        )
        XCTAssertEqual(inspect.sourceReferences, ["example/app:a", "example/app:z"])

        XCTAssertThrowsError(
            try makeRequest(
                operation: .pull,
                sources: ["example/app:a", "example/app:b"]
            )
        )
        XCTAssertThrowsError(
            try makeRequest(
                operation: .delete,
                sources: ["example/app:a", "example/app:a"]
            )
        )
        let overLimit = (0...RuntimeImageLifecycleLimits.maximumSourceReferencesPerRequest).map {
            "example/image\($0):v1"
        }
        XCTAssertThrowsError(
            try makeRequest(operation: .inspect, sources: overLimit)
        )
    }

    func testCanonicalRequestAndPlanDigestAreDeterministic() throws {
        let first = try makeRequest(
            operation: .build,
            target: "example/app:v1",
            contextPath: "/private/tmp/context",
            platformOS: "linux",
            platformArchitecture: "amd64",
            offline: true
        )
        let encoded = try first.canonicalJSONData()
        let decoded = try JSONDecoder().decode(RuntimeImageLifecycleRequest.self, from: encoded)

        XCTAssertEqual(first, decoded)
        XCTAssertEqual(try first.canonicalJSONData(), try decoded.canonicalJSONData())
        XCTAssertEqual(try first.planSHA256(), try decoded.planSHA256())
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            """
            {"capabilitySHA256":"\(capabilitySHA256)","contextPath":"/private/tmp/context","expectedSourceDigests":{},"idempotencyKey":"\(idempotencyKey)","maximumOutputBytes":1048576,"noCache":false,"offline":true,"operation":"build","operationID":"\(operationID)","platformArchitecture":"amd64","platformOS":"linux","schemaVersion":1,"sourceReferences":[],"targetReference":"example/app:v1"}
            """
        )
    }

    func testUnknownSecretAndForceLikeFieldsAreRejectedDuringDecode() throws {
        let request = try makeRequest(operation: .inspect, source: "app:v1")
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.canonicalJSONData()) as? [String: Any]
        )
        for (field, value): (String, Any) in [
            ("password", "must-not-enter-the-contract"),
            ("force", true),
            ("forceDelete", true)
        ] {
            var object = original
            object[field] = value
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(
                try JSONDecoder().decode(RuntimeImageLifecycleRequest.self, from: data)
            ) { error in
                XCTAssertEqual(
                    error as? RuntimeImageLifecycleContractError,
                    .unknownField(field)
                )
            }
        }
    }

    func testOneInputChangeChangesPlanDigest() throws {
        let first = try makeRequest(operation: .inspect, source: "app:v1")
        let second = try makeRequest(operation: .inspect, source: "app:v2")
        XCTAssertNotEqual(try first.planSHA256(), try second.planSHA256())
    }

    func testCapabilityContractSortsAllOperationsAndRequiresImplementedAvailable() throws {
        var statuses = RuntimeImageLifecycleOperation.allCases.reversed().map {
            RuntimeImageOperationCapability(
                operation: $0,
                state: .available,
                reason: .implemented
            )
        }
        statuses[0] = RuntimeImageOperationCapability(
            operation: statuses[0].operation,
            state: .unavailable,
            reason: .providerUnsupported
        )
        let contract = try RuntimeImageOperationCapabilityContract(
            providerID: .appleContainerCLI,
            capabilitySHA256: capabilitySHA256,
            operations: statuses
        )

        XCTAssertEqual(
            contract.operations.map(\.operation.rawValue),
            RuntimeImageLifecycleOperation.allCases.map(\.rawValue).sorted()
        )
        try contract.requireAvailable(.pull)
        let unavailable = statuses[0].operation
        XCTAssertThrowsError(try contract.requireAvailable(unavailable)) { error in
            XCTAssertEqual(
                error as? RuntimeImageLifecycleContractError,
                .unavailable(operation: unavailable, reason: .providerUnsupported)
            )
        }
    }

    func testCapabilityContractRejectsMissingDuplicateAndContradictoryStatuses() {
        let available = RuntimeImageLifecycleOperation.allCases.map {
            RuntimeImageOperationCapability(
                operation: $0,
                state: .available,
                reason: .implemented
            )
        }
        XCTAssertThrowsError(
            try RuntimeImageOperationCapabilityContract(
                providerID: .appleContainerCLI,
                capabilitySHA256: capabilitySHA256,
                operations: Array(available.dropLast())
            )
        )
        XCTAssertThrowsError(
            try RuntimeImageOperationCapabilityContract(
                providerID: .appleContainerCLI,
                capabilitySHA256: capabilitySHA256,
                operations: Array(available.dropLast()) + [available[0]]
            )
        )
        var contradictory = available
        contradictory[0] = RuntimeImageOperationCapability(
            operation: .pull,
            state: .blocked,
            reason: .implemented
        )
        XCTAssertThrowsError(
            try RuntimeImageOperationCapabilityContract(
                providerID: .appleContainerCLI,
                capabilitySHA256: capabilitySHA256,
                operations: contradictory
            )
        )
    }

    func testImageRecordNormalizesReferencesVariantsAndLayersDeterministically() throws {
        let firstLayer = "sha256:\(digestBody("1"))"
        let secondLayer = "sha256:\(digestBody("2"))"
        let arm64 = try RuntimeImageVariantRecord(
            digest: "sha256:\(digestBody("a"))",
            operatingSystem: "linux",
            architecture: "arm64",
            sizeBytes: 20,
            layerDigests: [secondLayer, firstLayer]
        )
        let amd64 = try RuntimeImageVariantRecord(
            digest: "sha256:\(digestBody("b"))",
            operatingSystem: "linux",
            architecture: "amd64",
            sizeBytes: 22
        )
        let record = try RuntimeImageRecord(
            digest: "sha256:\(digestBody("f"))",
            references: ["app:z", "app:a"],
            mediaType: "application/vnd.oci.image.index.v1+json",
            sizeBytes: 42,
            variants: [arm64, amd64],
            createdAtUnixSeconds: 1_700_000_000
        )

        XCTAssertEqual(record.references, ["app:a", "app:z"])
        XCTAssertEqual(record.variants.map(\.architecture), ["amd64", "arm64"])
        XCTAssertEqual(record.variants[1].layerDigests, [firstLayer, secondLayer])
        let roundTrip = try JSONDecoder().decode(
            RuntimeImageRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(roundTrip, record)
    }

    func testImageRecordRejectsDuplicateReferencesInvalidDigestAndNegativeSize() {
        XCTAssertThrowsError(
            try RuntimeImageRecord(
                digest: "not-a-digest",
                references: ["app:v1"],
                mediaType: "application/test",
                sizeBytes: 1,
                variants: [try makeVariant("1")]
            )
        )
        XCTAssertThrowsError(
            try RuntimeImageRecord(
                digest: "sha256:\(digestBody("1"))",
                references: ["app:v1", "app:v1"],
                mediaType: "application/test",
                sizeBytes: 1,
                variants: [try makeVariant("1")]
            )
        )
        XCTAssertThrowsError(
            try RuntimeImageRecord(
                digest: "sha256:\(digestBody("1"))",
                references: ["app:v1"],
                mediaType: "application/test",
                sizeBytes: -1,
                variants: [try makeVariant("1")]
            )
        )
    }

    func testImageRecordReferenceAndVariantOrderingIsPermutationInvariant() throws {
        let references = ["example/app:z", "example/app:a", "example/app:m"]
        let variants = [
            try makeVariant("a", architecture: "arm64"),
            try makeVariant("b", architecture: "amd64")
        ]
        let expected = try RuntimeImageRecord(
            digest: "sha256:\(digestBody("f"))",
            references: references,
            mediaType: "application/test",
            sizeBytes: 3,
            variants: variants
        )

        for offset in references.indices {
            let rotatedReferences =
                Array(references[offset...]) + Array(references[..<offset])
            let candidate = try RuntimeImageRecord(
                digest: expected.digest,
                references: rotatedReferences,
                mediaType: expected.mediaType,
                sizeBytes: expected.sizeBytes,
                variants: Array(variants.reversed())
            )
            XCTAssertEqual(candidate, expected)
        }
    }

    func testImageRecordRejectsMissingDuplicateAndInvalidVariants() throws {
        let arm64 = try makeVariant("1", architecture: "arm64")
        let otherArm64 = try makeVariant("2", architecture: "arm64")
        XCTAssertThrowsError(
            try RuntimeImageRecord(
                digest: "sha256:\(digestBody("f"))",
                references: ["app:v1"],
                mediaType: "application/test",
                sizeBytes: 1,
                variants: []
            )
        )
        XCTAssertThrowsError(
            try RuntimeImageRecord(
                digest: "sha256:\(digestBody("f"))",
                references: ["app:v1"],
                mediaType: "application/test",
                sizeBytes: 1,
                variants: [arm64, arm64]
            )
        )
        XCTAssertThrowsError(
            try RuntimeImageRecord(
                digest: "sha256:\(digestBody("f"))",
                references: ["app:v1"],
                mediaType: "application/test",
                sizeBytes: 1,
                variants: [arm64, otherArm64]
            )
        )
        XCTAssertThrowsError(
            try RuntimeImageVariantRecord(
                digest: "sha256:\(digestBody("3"))",
                operatingSystem: "linux",
                architecture: "x86_64",
                sizeBytes: 1
            )
        )
    }

    func testImageReferenceCountLimitIsExact() throws {
        let maximum = (0..<RuntimeImageLifecycleLimits.maximumReferencesPerImage).map {
            "example/image\($0):v1"
        }
        XCTAssertNoThrow(
            try RuntimeImageRecord(
                digest: "sha256:\(digestBody("1"))",
                references: maximum,
                mediaType: "application/test",
                sizeBytes: 1,
                variants: [try makeVariant("1")]
            )
        )
        XCTAssertThrowsError(
            try RuntimeImageRecord(
                digest: "sha256:\(digestBody("1"))",
                references: maximum + ["example/overflow:v1"],
                mediaType: "application/test",
                sizeBytes: 1,
                variants: [try makeVariant("1")]
            )
        )
    }

    func testResultSortsImagesAndDeletedDigestsAndPreservesExactIdentity() throws {
        let first = try RuntimeImageRecord(
            digest: "sha256:\(digestBody("1"))",
            references: ["app:v1"],
            mediaType: "application/test",
            sizeBytes: 1,
            variants: [try makeVariant("1")]
        )
        let second = try RuntimeImageRecord(
            digest: "sha256:\(digestBody("2"))",
            references: ["app:v2"],
            mediaType: "application/test",
            sizeBytes: 2,
            variants: [try makeVariant("2")]
        )
        let request = try makeRequest(operation: .prune, source: "app:v1")
        let result = try RuntimeImageOperationResult(
            operation: .prune,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            planSHA256: request.planSHA256(),
            providerID: .appleContainerCLI,
            providerVersion: "1.1.0",
            disposition: .succeeded,
            images: [second, first],
            deletedDigests: [second.digest, first.digest],
            reclaimedBytes: 3
        )

        XCTAssertEqual(result.images.map(\.digest), [first.digest, second.digest])
        XCTAssertEqual(result.deletedDigests, [first.digest, second.digest])
        XCTAssertEqual(result.operationID, request.operationID)
        XCTAssertEqual(result.idempotencyKey, request.idempotencyKey)
    }

    func testProgressPreservesExactIdentityAndEnforcesBounds() throws {
        let request = try makeRequest(operation: .pull, source: "example/app:v1")
        let event = try RuntimeImageProgressEvent(
            operation: request.operation,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            sequence: 3,
            stage: .downloading,
            completedBytes: 50,
            totalBytes: 100,
            itemDigest: "sha256:\(digestBody("4"))",
            itemReference: "example/app:v1"
        )

        XCTAssertEqual(event.operationID, request.operationID)
        XCTAssertEqual(event.idempotencyKey, request.idempotencyKey)
        XCTAssertThrowsError(
            try RuntimeImageProgressEvent(
                operation: .pull,
                operationID: operationID,
                idempotencyKey: idempotencyKey,
                sequence: UInt64(RuntimeImageLifecycleLimits.maximumProgressEvents),
                stage: .downloading,
                completedBytes: 101,
                totalBytes: 100
            )
        )
    }

    private func makeRequest(
        operation: RuntimeImageLifecycleOperation,
        operationID: String? = nil,
        idempotencyKey: String? = nil,
        capabilitySHA256: String? = nil,
        source: String? = nil,
        sources: [String]? = nil,
        expectedSourceDigests: [String: String]? = nil,
        target: String? = nil,
        contextPath: String? = nil,
        dockerfilePath: String? = nil,
        archivePath: String? = nil,
        platformOS: String? = nil,
        platformArchitecture: String? = nil,
        offline: Bool = false,
        noCache: Bool = false,
        maximumOutputBytes: Int = RuntimeImageLifecycleLimits.defaultOutputBytes
    ) throws -> RuntimeImageLifecycleRequest {
        let resolvedSources = sources ?? [source].compactMap { $0 }
        let digestBound = operation == .push ||
            operation == .tag ||
            operation == .save ||
            operation == .delete ||
            operation == .prune
        return try RuntimeImageLifecycleRequest(
            operation: operation,
            operationID: operationID ?? self.operationID,
            idempotencyKey: idempotencyKey ?? self.idempotencyKey,
            capabilitySHA256: capabilitySHA256 ?? self.capabilitySHA256,
            sourceReferences: resolvedSources,
            expectedSourceDigests: expectedSourceDigests ??
                (digestBound
                    ? Dictionary(
                        resolvedSources.map {
                            ($0, "sha256:\(digestBody("1"))")
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    : [:]),
            targetReference: target,
            contextPath: contextPath,
            dockerfilePath: dockerfilePath,
            archivePath: archivePath,
            platformOS: platformOS,
            platformArchitecture: platformArchitecture,
            offline: offline,
            noCache: noCache,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private func digestBody(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func makeVariant(
        _ character: Character,
        architecture: String = "arm64",
        sizeBytes: Int64 = 1,
        layerDigests: [String] = []
    ) throws -> RuntimeImageVariantRecord {
        try RuntimeImageVariantRecord(
            digest: "sha256:\(digestBody(character))",
            operatingSystem: "linux",
            architecture: architecture,
            sizeBytes: sizeBytes,
            layerDigests: layerDigests
        )
    }

    private func assertThrows(
        _ expected: RuntimeImageLifecycleContractError,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? RuntimeImageLifecycleContractError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

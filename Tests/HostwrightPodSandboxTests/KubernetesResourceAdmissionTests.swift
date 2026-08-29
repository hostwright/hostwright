import Foundation
import HostwrightPodSandbox
import XCTest

final class KubernetesResourceAdmissionTests: XCTestCase {
    func testCanonicalCPUAndMemoryQuantitiesNormalizeExactly() throws {
        let cpuCases: [(String, Int64)] = [
            ("1", 1_000),
            ("0.001", 1),
            ("1.25", 1_250),
            ("250m", 250),
            ("9223372036854775807m", .max),
        ]
        for (raw, expected) in cpuCases {
            let result = KubernetesResourceAdmission.admitPod([
                container(requests: [("cpu", raw)]),
            ])
            let admission = try XCTUnwrap(result.admission, raw)
            XCTAssertEqual(admission.containers[0].requests.cpuMillicores, expected, raw)
            XCTAssertNil(admission.containers[0].requests.memoryBytes, raw)
        }

        let memoryCases: [(String, Int64)] = [
            ("1", 1),
            ("1Ki", 1_024),
            ("2Mi", 2_097_152),
            ("3Gi", 3_221_225_472),
            ("4k", 4_000),
            ("5M", 5_000_000),
            ("6G", 6_000_000_000),
            ("9223372036854775807", .max),
        ]
        for (raw, expected) in memoryCases {
            let result = KubernetesResourceAdmission.admitPod([
                container(limits: [("memory", raw)]),
            ])
            let admission = try XCTUnwrap(result.admission, raw)
            XCTAssertEqual(admission.containers[0].limits.memoryBytes, expected, raw)
            XCTAssertNil(admission.containers[0].limits.cpuMillicores, raw)
        }
    }

    func testUnsafeFractionsMalformedValuesUnitsOverflowAndNonpositiveValuesFailClosed() {
        let cases: [(String, String, KubernetesResourceAdmissionDiagnosticCode)] = [
            ("cpu", "0.0001", .invalidQuantity),
            ("cpu", ".5", .invalidQuantity),
            ("cpu", "1.", .invalidQuantity),
            ("cpu", "1e3", .invalidQuantity),
            ("cpu", "+1", .invalidQuantity),
            ("cpu", "-1", .invalidQuantity),
            ("cpu", "1.5m", .invalidQuantity),
            ("cpu", "1u", .unsupportedUnit),
            ("cpu", "1M", .unsupportedUnit),
            ("cpu", "01", .invalidQuantity),
            ("cpu", "00.5", .invalidQuantity),
            ("cpu", "١", .invalidQuantity),
            ("cpu", "0", .nonPositiveQuantity),
            ("cpu", "0m", .nonPositiveQuantity),
            ("cpu", "9223372036854775808m", .quantityOverflow),
            ("memory", "1.5Gi", .invalidQuantity),
            ("memory", "1e3", .invalidQuantity),
            ("memory", "-1Gi", .invalidQuantity),
            ("memory", "1mi", .unsupportedUnit),
            ("memory", "1ki", .unsupportedUnit),
            ("memory", "1KI", .unsupportedUnit),
            ("memory", "1K", .unsupportedUnit),
            ("memory", "01Mi", .invalidQuantity),
            ("memory", "0Gi", .nonPositiveQuantity),
            ("memory", "9223372036854775808", .quantityOverflow),
            ("memory", "9223372036854775807Gi", .quantityOverflow),
        ]

        for (key, raw, expectedCode) in cases {
            let result = KubernetesResourceAdmission.admitPod([
                container(requests: [(key, raw)]),
            ])
            XCTAssertNil(result.admission, "\(key)=\(raw)")
            XCTAssertEqual(result.diagnostics.map(\.code), [expectedCode], "\(key)=\(raw)")
            XCTAssertEqual(
                result.diagnostics.first?.path,
                "$.spec.containers[0].resources.requests.\(key)",
                "\(key)=\(raw)"
            )
        }
    }

    func testUnsupportedDuplicateAndMissingResourceEntriesAreRejectedDeterministically() {
        let first = KubernetesResourceAdmission.admitPod([
            container(requests: [
                ("example.com/gpu", "1"),
                ("cpu", "2"),
                ("memory", nil),
                ("ephemeral-storage", "1Gi"),
                ("cpu", "1"),
                ("hugepages-2Mi", "1Mi"),
            ]),
        ])
        let reordered = KubernetesResourceAdmission.admitPod([
            container(requests: [
                ("hugepages-2Mi", "1Mi"),
                ("cpu", "1"),
                ("ephemeral-storage", "1Gi"),
                ("memory", nil),
                ("cpu", "2"),
                ("example.com/gpu", "1"),
            ]),
        ])

        XCTAssertEqual(first, reordered)
        XCTAssertNil(first.admission)
        XCTAssertEqual(
            first.diagnostics.map(\.code),
            [
                .duplicateResource,
                .missingQuantity,
                .unsupportedResource,
                .unsupportedResource,
                .unsupportedResource,
            ]
        )
        XCTAssertEqual(
            first.diagnostics.map(\.path),
            [
                "$.spec.containers[0].resources.requests.cpu",
                "$.spec.containers[0].resources.requests.memory",
                "$.spec.containers[0].resources.requests[\"ephemeral-storage\"]",
                "$.spec.containers[0].resources.requests[\"example.com/gpu\"]",
                "$.spec.containers[0].resources.requests[\"hugepages-2Mi\"]",
            ]
        )
    }

    func testHostileResourceKeysAndOversizedMapsHaveBoundedDeterministicPaths() {
        let hostile = KubernetesResourceAdmission.admitPod([
            container(requests: [("bad\"\\\n", "1")]),
        ])
        XCTAssertNil(hostile.admission)
        XCTAssertEqual(hostile.diagnostics.map(\.code), [.unsupportedResource])
        XCTAssertEqual(
            hostile.diagnostics.map(\.path),
            ["$.spec.containers[0].resources.requests[\"bad\\\"\\\\\\u000A\"]"]
        )

        let oversized = KubernetesResourceAdmission.admitPod([
            container(requests: Array(
                repeating: ("cpu", "1"),
                count: KubernetesResourceAdmission.maximumResourceEntriesPerMap + 1
            )),
        ])
        XCTAssertNil(oversized.admission)
        XCTAssertEqual(oversized.diagnostics.map(\.code), [.invalidResourceEntryCount])
        XCTAssertEqual(
            oversized.diagnostics.map(\.path),
            ["$.spec.containers[0].resources.requests"]
        )
    }

    func testRequestsCannotExceedLimitsButMissingSidesStayExplicit() throws {
        let rejected = KubernetesResourceAdmission.admitPod([
            container(
                requests: [("memory", "2Gi"), ("cpu", "2")],
                limits: [("cpu", "1500m"), ("memory", "1Gi")]
            ),
        ])
        XCTAssertNil(rejected.admission)
        XCTAssertEqual(rejected.diagnostics.map(\.code), [.requestExceedsLimit, .requestExceedsLimit])
        XCTAssertEqual(
            rejected.diagnostics.map(\.path),
            [
                "$.spec.containers[0].resources.requests.cpu",
                "$.spec.containers[0].resources.requests.memory",
            ]
        )

        let accepted = KubernetesResourceAdmission.admitPod([
            container(requests: [("memory", "1Mi")], limits: [("cpu", "2")]),
        ])
        let resources = try XCTUnwrap(accepted.admission?.containers[0])
        XCTAssertNil(resources.requests.cpuMillicores)
        XCTAssertEqual(resources.requests.memoryBytes, 1_048_576)
        XCTAssertEqual(resources.limits.cpuMillicores, 2_000)
        XCTAssertNil(resources.limits.memoryBytes)
    }

    func testMultiContainerAndDeploymentTotalsUseCheckedArithmetic() throws {
        let pod = KubernetesResourceAdmission.admitPod([
            container(requests: [("cpu", "500m"), ("memory", "1Gi")]),
            container(requests: [("cpu", "1.5"), ("memory", "500M")]),
        ])
        let podAdmission = try XCTUnwrap(pod.admission)
        XCTAssertEqual(podAdmission.perReplicaRequests.cpuMillicores, 2_000)
        XCTAssertEqual(podAdmission.perReplicaRequests.memoryBytes, 1_573_741_824)
        XCTAssertEqual(podAdmission.aggregateRequests, podAdmission.perReplicaRequests)
        XCTAssertEqual(podAdmission.replicas, 1)

        let deployment = KubernetesResourceAdmission.admitDeployment(
            [container(limits: [("cpu", "750m"), ("memory", "2Mi")])],
            replicas: 3
        )
        let deploymentAdmission = try XCTUnwrap(deployment.admission)
        XCTAssertEqual(deploymentAdmission.perReplicaLimits.cpuMillicores, 750)
        XCTAssertEqual(deploymentAdmission.aggregateLimits.cpuMillicores, 2_250)
        XCTAssertEqual(deploymentAdmission.aggregateLimits.memoryBytes, 6_291_456)
        XCTAssertEqual(deploymentAdmission.replicas, 3)

        let partial = KubernetesResourceAdmission.admitPod([
            container(requests: [("cpu", "500m")], limits: [("cpu", "1")]),
            container(requests: [("memory", "1Mi")]),
        ])
        let partialAdmission = try XCTUnwrap(partial.admission)
        XCTAssertEqual(partialAdmission.perReplicaRequests.cpuMillicores, 500)
        XCTAssertEqual(partialAdmission.perReplicaRequests.memoryBytes, 1_048_576)
        XCTAssertNil(partialAdmission.perReplicaLimits.cpuMillicores)
        XCTAssertNil(partialAdmission.perReplicaLimits.memoryBytes)
    }

    func testAggregateAndReplicaMultiplicationOverflowArePathAware() {
        let aggregate = KubernetesResourceAdmission.admitPod([
            container(limits: [("memory", "9223372036854775807")]),
            container(limits: [("memory", "1")]),
        ])
        XCTAssertNil(aggregate.admission)
        XCTAssertEqual(aggregate.diagnostics.map(\.code), [.aggregateOverflow])
        XCTAssertEqual(aggregate.diagnostics.first?.path, "$.spec.containers")

        let replica = KubernetesResourceAdmission.admitDeployment(
            [container(requests: [("memory", "9223372036854775807")])],
            replicas: 2
        )
        XCTAssertNil(replica.admission)
        XCTAssertEqual(replica.diagnostics.map(\.code), [.replicaOverflow])
        XCTAssertEqual(replica.diagnostics.first?.path, "$.spec.replicas")

        for invalidReplicas in [Int64.min, -1, 0] {
            let invalid = KubernetesResourceAdmission.admitDeployment(
                [container()],
                replicas: invalidReplicas
            )
            XCTAssertNil(invalid.admission)
            XCTAssertEqual(invalid.diagnostics.map(\.code), [.invalidReplicaCount])
            XCTAssertEqual(invalid.diagnostics.first?.path, "$.spec.replicas")
        }
    }

    func testEmptyAndOversizedContainerCollectionsAreRejected() {
        let empty = KubernetesResourceAdmission.admitPod([])
        XCTAssertNil(empty.admission)
        XCTAssertEqual(empty.diagnostics.map(\.code), [.invalidContainerCount])
        XCTAssertEqual(empty.diagnostics.first?.path, "$.spec.containers")

        let oversized = KubernetesResourceAdmission.admitPod(
            Array(repeating: container(), count: KubernetesResourceAdmission.maximumContainers + 1)
        )
        XCTAssertNil(oversized.admission)
        XCTAssertEqual(oversized.diagnostics.map(\.code), [.invalidContainerCount])
    }

    func testCodableRoundTripRevalidatesNormalizedDomainAndDerivedTotals() throws {
        let result = KubernetesResourceAdmission.admitDeployment(
            [container(requests: [("cpu", "500m")], limits: [("memory", "1Gi")])],
            replicas: 2
        )
        let admission = try XCTUnwrap(result.admission)
        XCTAssertEqual(admission.schemaVersion, KubernetesResourceAdmission.schemaVersion)
        XCTAssertEqual(admission.supportedSubset, KubernetesResourceAdmission.supportedSubset)
        let encoded = try JSONEncoder().encode(admission)
        XCTAssertEqual(try JSONDecoder().decode(KubernetesWorkloadComputeResources.self, from: encoded), admission)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"memoryBytes\":null"))

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                KubernetesComputeResources.self,
                from: Data("{\"cpuMillicores\":-1,\"memoryBytes\":null}".utf8)
            )
        )

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var aggregate = try XCTUnwrap(object["aggregateRequests"] as? [String: Any])
        aggregate["cpuMillicores"] = 999
        object["aggregateRequests"] = aggregate
        let inconsistent = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try JSONDecoder().decode(KubernetesWorkloadComputeResources.self, from: inconsistent)
        )

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["supportedSubset"] = "kubernetes.resource.Quantity"
        let unsupported = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try JSONDecoder().decode(KubernetesWorkloadComputeResources.self, from: unsupported)
        )

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = KubernetesResourceAdmission.schemaVersion + 1
        let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try JSONDecoder().decode(KubernetesWorkloadComputeResources.self, from: future)
        )

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["unknown"] = true
        let unknown = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try JSONDecoder().decode(KubernetesWorkloadComputeResources.self, from: unknown)
        )

        let explicitNulls = try JSONDecoder().decode(
            KubernetesComputeResources.self,
            from: Data("{\"cpuMillicores\":null,\"memoryBytes\":null}".utf8)
        )
        XCTAssertNil(explicitNulls.cpuMillicores)
        XCTAssertNil(explicitNulls.memoryBytes)

        let omittedKeyCases = [
            (json: "{}", expectedKey: "cpuMillicores"),
            (json: "{\"memoryBytes\":null}", expectedKey: "cpuMillicores"),
            (json: "{\"cpuMillicores\":null}", expectedKey: "memoryBytes"),
        ]
        for testCase in omittedKeyCases {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    KubernetesComputeResources.self,
                    from: Data(testCase.json.utf8)
                ),
                testCase.json
            ) { error in
                guard case DecodingError.keyNotFound(let key, _) = error else {
                    return XCTFail("Expected keyNotFound for \(testCase.json), got \(error)")
                }
                XCTAssertEqual(key.stringValue, testCase.expectedKey, testCase.json)
            }
        }
    }

    private func container(
        requests: [(String, String?)] = [],
        limits: [(String, String?)] = []
    ) -> KubernetesContainerResourceRequirements {
        KubernetesContainerResourceRequirements(
            requests: requests.map(KubernetesResourceQuantityEntry.init),
            limits: limits.map(KubernetesResourceQuantityEntry.init)
        )
    }
}

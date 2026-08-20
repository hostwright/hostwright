import Foundation
import XCTest
@testable import HostwrightDesktopModel

final class DesktopTopologyProjectionTests: XCTestCase {
    func testProjectionHasStableOrderingAndOnlyExplicitRelationships() throws {
        let alpha = project(
            id: "project-alpha",
            name: "Alpha",
            services: [
                service(id: "worker"),
                service(
                    id: "api",
                    resourceIdentifier: "runtime-api-1",
                    lifecycle: "running",
                    health: "healthy"
                ),
            ]
        )
        let beta = project(
            id: "project-beta",
            name: "Beta",
            services: [service(id: "web", lifecycle: "starting")]
        )

        let first = try DesktopTopologyProjector.project(
            daemonHealth: daemon(readiness: "running"),
            projects: [beta, alpha],
            events: []
        )
        let second = try DesktopTopologyProjector.project(
            daemonHealth: daemon(readiness: "running"),
            projects: [alpha, beta],
            events: []
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.nodes.map(\.id), first.nodes.map(\.id).sorted())
        XCTAssertEqual(first.edges.map(\.id), first.edges.map(\.id).sorted())
        XCTAssertEqual(Set(first.edges.map(\.kind)), [.projectReportsService, .serviceReportsRuntimeResource])
        XCTAssertEqual(
            first.edges.filter { $0.kind == .projectReportsService }.count,
            3
        )
        XCTAssertEqual(
            first.edges.filter { $0.kind == .serviceReportsRuntimeResource }.count,
            1
        )
        XCTAssertEqual(
            first.nodes.filter { $0.kind == .runtimeResource }.map(\.label),
            ["Runtime resource"]
        )
        XCTAssertEqual(
            first.nodes.first { $0.kind == .project && $0.label == "Alpha" }?.id,
            "node.project.70726f6a6563742d616c706861"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
        XCTAssertEqual(
            try DesktopTopologyWireContract.decode(DesktopTopologyWireContract.encode(first)),
            first
        )
    }

    func testUnknownReportedStateStaysUnknownWithoutImplicitReachabilityOrHealth() throws {
        let document = try DesktopTopologyProjector.project(
            daemonHealth: daemon(readiness: "vendor-new-state"),
            projects: [
                project(
                    id: "project-alpha",
                    name: "Alpha",
                    services: [
                        service(
                            id: "api",
                            resourceIdentifier: "runtime-api-1",
                            lifecycle: "running",
                            health: nil
                        )
                    ]
                )
            ],
            events: []
        )

        XCTAssertEqual(document.scope, .localReportedOnly)
        XCTAssertEqual(document.nodes.first { $0.kind == .daemon }?.severity, .unknown)
        XCTAssertEqual(document.nodes.first { $0.kind == .project }?.severity, .unknown)
        XCTAssertEqual(document.nodes.first { $0.kind == .service }?.severity, .unknown)
        XCTAssertEqual(document.nodes.first { $0.kind == .runtimeResource }?.severity, .unknown)

        let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        XCTAssertFalse(encoded.contains("reachable"))
        XCTAssertFalse(encoded.contains("ownership"))
        XCTAssertFalse(encoded.contains("cluster"))
        XCTAssertFalse(encoded.contains("fleet"))
    }

    func testDuplicateAndConflictingIdentifiersFailClosed() throws {
        let duplicateProject = project(id: "project-alpha", name: "Alpha", services: [])
        XCTAssertThrowsError(
            try DesktopTopologyProjector.project(
                daemonHealth: nil,
                projects: [duplicateProject, duplicateProject],
                events: []
            )
        ) { error in
            XCTAssertEqual(
                error as? DesktopTopologyProjectionError,
                .duplicateIdentifier(role: "project", value: "project-alpha")
            )
        }

        XCTAssertThrowsError(
            try DesktopTopologyProjector.project(
                daemonHealth: nil,
                projects: [
                    project(
                        id: "project-alpha",
                        name: "Alpha",
                        services: [service(id: "api"), service(id: "api")]
                    )
                ],
                events: []
            )
        ) { error in
            XCTAssertEqual(
                error as? DesktopTopologyProjectionError,
                .duplicateIdentifier(role: "service", value: "project-alpha/api")
            )
        }

        XCTAssertThrowsError(
            try DesktopTopologyProjector.project(
                daemonHealth: nil,
                projects: [
                    project(
                        id: "project-alpha",
                        name: "Alpha",
                        services: [
                            service(id: "api", resourceIdentifier: "runtime-shared"),
                            service(id: "worker", resourceIdentifier: "runtime-shared"),
                        ]
                    )
                ],
                events: []
            )
        ) { error in
            XCTAssertEqual(
                error as? DesktopTopologyProjectionError,
                .conflictingIdentifier(role: "runtime-resource", value: "runtime-shared")
            )
        }
    }

    func testComponentEncodedIdentifiersDoNotConflateSeparatorPlacements() throws {
        let document = try DesktopTopologyProjector.project(
            daemonHealth: nil,
            projects: [
                project(id: "a/b", name: "First", services: [service(id: "c")]),
                project(id: "a", name: "Second", services: [service(id: "b/c")]),
            ],
            events: []
        )

        let serviceNodes = document.nodes.filter { $0.kind == .service }
        XCTAssertEqual(serviceNodes.count, 2)
        XCTAssertEqual(Set(serviceNodes.map(\.id)).count, 2)
        XCTAssertEqual(
            document.edges.filter { $0.kind == .projectReportsService }.count,
            2
        )
    }

    func testLabelsAndDiagnosticsAreBoundedRedactedAndControlFree() throws {
        let secret = "synthetic-top-secret"
        let document = try DesktopTopologyProjector.project(
            daemonHealth: daemon(readiness: "running"),
            projects: [
                project(
                    id: "project-alpha",
                    name: "token=\(secret)\n\t" + String(repeating: "A", count: 500),
                    services: [service(id: "api")]
                )
            ],
            events: [
                event(
                    id: "event-1",
                    severity: "warning",
                    type: "authorization=\(secret)\nchanged",
                    source: "credential=\(secret)",
                    message: "password=\(secret)",
                    payloadJSONRedacted: #"{"opaque":"do-not-copy"}"#
                )
            ]
        )

        let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("do-not-copy"))
        XCTAssertTrue(document.nodes.allSatisfy { $0.label.utf8.count <= 96 })
        XCTAssertTrue(document.nodes.allSatisfy { $0.detail.utf8.count <= 256 })
        XCTAssertTrue(document.diagnostics.allSatisfy { $0.summary.utf8.count <= 160 })
        XCTAssertTrue(document.diagnostics.allSatisfy { $0.detail.utf8.count <= 256 })

        for value in document.nodes.flatMap({ [$0.label, $0.detail, $0.accessibilitySummary] })
            + document.diagnostics.flatMap({ [$0.summary, $0.detail, $0.accessibilitySummary] }) {
            XCTAssertFalse(value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        }

        XCTAssertThrowsError(
            try DesktopTopologyProjector.project(
                daemonHealth: nil,
                projects: [project(id: "token=must-not-be-encoded", name: "Unsafe", services: [])],
                events: []
            )
        ) { error in
            XCTAssertFalse(String(describing: error).contains("must-not-be-encoded"))
        }
    }

    func testEventsAssociateOnlyThroughExactReportedProjectAndServiceIdentifiers() throws {
        let document = try DesktopTopologyProjector.project(
            daemonHealth: nil,
            projects: [
                project(
                    id: "project-alpha",
                    name: "Alpha",
                    services: [service(id: "api")]
                )
            ],
            events: [
                event(
                    id: "event-exact",
                    severity: "error",
                    projectID: "project-alpha",
                    serviceName: "api",
                    runtimeAdapter: "apple-container"
                ),
                event(
                    id: "event-service-only",
                    severity: "info",
                    projectID: nil,
                    serviceName: "api"
                ),
                event(
                    id: "event-unknown-project",
                    severity: "warning",
                    projectID: "project-other",
                    serviceName: "api"
                ),
            ]
        )

        let exact = try XCTUnwrap(
            document.diagnostics.first { $0.id.hasSuffix("6576656e742d6578616374") }
        )
        XCTAssertEqual(exact.relatedNodeIDs.count, 2)
        XCTAssertEqual(exact.reportedRuntimeAdapter, "apple-container")
        XCTAssertEqual(exact.severity, .critical)

        let serviceOnly = try XCTUnwrap(
            document.diagnostics.first { $0.id.hasSuffix("6576656e742d736572766963652d6f6e6c79") }
        )
        XCTAssertTrue(serviceOnly.relatedNodeIDs.isEmpty)

        let unknownProject = try XCTUnwrap(
            document.diagnostics.first { $0.id.hasSuffix("6576656e742d756e6b6e6f776e2d70726f6a656374") }
        )
        XCTAssertTrue(unknownProject.relatedNodeIDs.isEmpty)
    }

    func testAccessibilitySummariesNameStateAndSeverityWithoutDependingOnColor() throws {
        let document = try DesktopTopologyProjector.project(
            daemonHealth: daemon(readiness: "stopped"),
            projects: [
                project(
                    id: "project-alpha",
                    name: "Alpha",
                    services: [service(id: "api", lifecycle: "running", health: "healthy")]
                )
            ],
            events: [event(id: "event-1", severity: "warning")]
        )

        XCTAssertTrue(document.nodes.allSatisfy { $0.accessibilitySummary.contains("State") })
        XCTAssertTrue(document.nodes.allSatisfy { $0.accessibilitySummary.contains("Severity") })
        XCTAssertTrue(document.diagnostics.allSatisfy { $0.accessibilitySummary.contains("Severity") })
        XCTAssertTrue(document.accessibilitySummary.contains("reported local topology"))
        XCTAssertFalse(document.accessibilitySummary.lowercased().contains("color"))
    }

    func testWireContractRejectsWrongSchemaUnknownNestedKeysDuplicateNestedKeysUnsortedNodesAndDanglingEdges() throws {
        let document = try DesktopTopologyProjector.project(
            daemonHealth: daemon(readiness: "running"),
            projects: [project(id: "project-alpha", name: "Alpha", services: [service(id: "api")])],
            events: []
        )
        let data = try DesktopTopologyWireContract.encode(document)
        XCTAssertEqual(try DesktopTopologyWireContract.decode(data), document)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        object["schemaVersion"] = 2
        XCTAssertThrowsError(
            try DesktopTopologyWireContract.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unknown"] = true
        XCTAssertThrowsError(
            try DesktopTopologyWireContract.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DesktopTopologyDocument.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        let duplicateNested = """
        {
          "schemaVersion": 1,
          "supportedSubset": "desktop-local-reported-topology-v1",
          "scope": "local-reported-only",
          "nodes": [{
            "id": "node.daemon.local",
            "kind": "daemon",
            "label": "Hostwright daemon",
            "label": "Hostwright daemon",
            "reportedState": "running",
            "severity": "normal",
            "detail": "Reported reason reported in domain local.",
            "accessibilitySummary": "Daemon Hostwright daemon. State running. Severity Normal."
          }],
          "edges": [],
          "diagnostics": [],
          "accessibilitySummary": "Reported local topology: 1 nodes, 0 explicit relationships, and 0 event diagnostics. Unknown states remain unknown."
        }
        """
        XCTAssertThrowsError(
            try DesktopTopologyWireContract.decode(Data(duplicateNested.utf8))
        )

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        nodes[0]["unexpected"] = true
        object["nodes"] = nodes
        XCTAssertThrowsError(
            try DesktopTopologyWireContract.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DesktopTopologyDocument.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["nodes"] = Array(
            try XCTUnwrap(object["nodes"] as? [[String: Any]]).reversed()
        )
        XCTAssertThrowsError(
            try DesktopTopologyWireContract.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var edges = try XCTUnwrap(object["edges"] as? [[String: Any]])
        edges[0]["targetNodeID"] = "node.service.deadbeef"
        object["edges"] = edges
        XCTAssertThrowsError(
            try DesktopTopologyWireContract.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testWireContractRejectsOversizedAndDeeplyNestedPayloads() throws {
        let document = try DesktopTopologyProjector.project(
            daemonHealth: daemon(readiness: "running"),
            projects: [project(id: "project-alpha", name: "Alpha", services: [service(id: "api")])],
            events: []
        )
        let data = try DesktopTopologyWireContract.encode(document)
        let oversized = data + Data(repeating: 0x20, count: 262_145)

        XCTAssertThrowsError(try DesktopTopologyWireContract.decode(oversized)) { error in
            XCTAssertEqual(
                error as? DesktopTopologyProjectionError,
                .invalidDocument("The topology JSON input exceeds its bounded subset.")
            )
        }

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var nested: Any = "too-deep"
        for _ in 0..<80 {
            nested = [nested]
        }
        object["accessibilitySummary"] = nested
        XCTAssertThrowsError(
            try DesktopTopologyWireContract.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(
                error as? DesktopTopologyProjectionError,
                .invalidDocument("The topology JSON input exceeds its bounded subset.")
            )
        }
    }

    private func daemon(readiness: String) -> DesktopDaemonHealth {
        DesktopDaemonHealth(
            readiness: readiness,
            reasonCode: "reported",
            label: "Hostwright daemon",
            domain: "local",
            generation: nil,
            processID: nil
        )
    }

    private func project(
        id: String,
        name: String,
        services: [DesktopServiceStatus]
    ) -> DesktopProjectStatus {
        DesktopProjectStatus(
            id: id,
            name: name,
            manifestPath: "/project/hostwright.yml",
            manifestIsValid: true,
            services: services,
            planHash: nil
        )
    }

    private func service(
        id: String,
        resourceIdentifier: String? = nil,
        lifecycle: String? = nil,
        health: String? = nil
    ) -> DesktopServiceStatus {
        DesktopServiceStatus(
            id: id,
            desiredImage: nil,
            resourceIdentifier: resourceIdentifier,
            observedImage: nil,
            lifecycle: lifecycle,
            health: health
        )
    }

    private func event(
        id: String,
        severity: String,
        type: String = "runtime.reported",
        source: String = "hostwright-daemon",
        message: String = "A bounded reported event occurred.",
        payloadJSONRedacted: String = "{}",
        projectID: String? = nil,
        serviceName: String? = nil,
        runtimeAdapter: String? = nil
    ) -> DesktopEvent {
        DesktopEvent(
            id: id,
            position: 1,
            timestamp: "2026-08-13T00:00:00Z",
            severity: severity,
            type: type,
            source: source,
            projectID: projectID,
            serviceName: serviceName,
            runtimeAdapter: runtimeAdapter,
            message: message,
            payloadJSONRedacted: payloadJSONRedacted,
            eventReference: "event-reference",
            operationReferences: []
        )
    }
}

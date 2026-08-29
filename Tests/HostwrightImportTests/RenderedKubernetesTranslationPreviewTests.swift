import HostwrightImport
import XCTest

final class RenderedKubernetesTranslationPreviewTests: XCTestCase {
    func testResourceLessWorkloadsFailClosedBeforeManifestEmission() {
        let result = RenderedKubernetesTranslationPreview.translate(
            successful([
                pod(
                    documentIndex: 1,
                    name: "api",
                    labels: [label("app", "api")],
                    image: "example.invalid/api:v1"
                ),
                deployment(
                    documentIndex: 2,
                    name: "worker",
                    namespace: "production",
                    replicas: 3,
                    selector: [label("app", "worker")],
                    image: "example.invalid/worker:v2"
                ),
            ])
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.errors.map(\.code), [.resourceAdmissionUnavailable])
        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
        XCTAssertTrue(result.errors[0].message.contains("validated compute-resource admission"))
        XCTAssertEqual(
            result.untranslated.map(\.path),
            [
                "$.metadata.labels",
                "$.spec.containers[0].name",
                "$.spec.selector.matchLabels",
                "$.spec.template.metadata.labels",
                "$.spec.template.spec.containers[0].name",
            ]
        )
    }

    func testResolvableClusterIPServiceFailsClosedInsteadOfPublishingHostPort() {
        let result = RenderedKubernetesTranslationPreview.translate(
            successful([
                pod(documentIndex: 1, name: "api", labels: [label("app", "api")]),
                service(
                    documentIndex: 2,
                    name: "api",
                    selector: [label("app", "api")],
                    ports: [port(port: 80, targetPort: 8_080)]
                ),
            ])
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
        XCTAssertEqual(result.errors.map(\.code), [.clusterIPServiceUnsupported])
        XCTAssertTrue(result.errors[0].message.contains("80/TCP -> 8080"))
        XCTAssertTrue(result.errors[0].message.contains("refuses to publish a host endpoint"))
    }

    func testServiceSelectorMustResolveExactlyOneWorkloadInItsNamespace() {
        let ambiguous = RenderedKubernetesTranslationPreview.translate(
            successful([
                pod(documentIndex: 1, name: "api-a", labels: [label("app", "api")]),
                pod(documentIndex: 2, name: "api-b", labels: [label("app", "api")]),
                service(documentIndex: 3, name: "api", selector: [label("app", "api")]),
            ])
        )
        XCTAssertEqual(ambiguous.errors.map(\.code), [.selectorTargetAmbiguous])
        XCTAssertTrue(ambiguous.errors[0].message.contains("Pod/default/api-a, Pod/default/api-b"))
        XCTAssertNil(ambiguous.manifest)

        let missing = RenderedKubernetesTranslationPreview.translate(
            successful([
                pod(
                    documentIndex: 1,
                    name: "api",
                    namespace: "other",
                    labels: [label("app", "api")]
                ),
                service(documentIndex: 2, name: "api", selector: [label("app", "api")]),
            ])
        )
        XCTAssertEqual(missing.errors.map(\.code), [.selectorTargetMissing])
        XCTAssertNil(missing.manifest)
    }

    func testDeploymentTemplateOnlySelectorMatchIsReportedAsIndeterminate() {
        let result = RenderedKubernetesTranslationPreview.translate(
            successful([
                deployment(
                    documentIndex: 1,
                    name: "api",
                    replicas: 1,
                    selector: [label("app", "api")],
                    image: "example.invalid/api:v1"
                ),
                service(
                    documentIndex: 2,
                    name: "api",
                    selector: [label("tier", "web")]
                ),
            ])
        )

        XCTAssertEqual(result.errors.map(\.code), [.selectorResolutionIndeterminate])
        XCTAssertFalse(result.errors.contains { $0.code == .selectorTargetMissing })
        XCTAssertTrue(result.errors[0].message.contains("Deployment/default/api"))
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
    }

    func testServiceOnlyInputReportsNoWorkloadsBeforeSelectorAnalysis() {
        let result = RenderedKubernetesTranslationPreview.translate(
            successful([
                service(
                    documentIndex: 1,
                    name: "orphan",
                    selector: [label("app", "missing")]
                ),
            ])
        )

        XCTAssertEqual(result.errors.map(\.code), [.noWorkloads])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
    }

    func testRejectsMultipleContainersWithoutPartialManifest() {
        let object = RenderedKubernetesObjectSummary(
            documentIndex: 1,
            apiVersion: "v1",
            kind: .pod,
            name: "joined",
            namespace: "default",
            labels: [],
            containers: [
                RenderedKubernetesContainerSummary(name: "api", image: "example.invalid/api:v1"),
                RenderedKubernetesContainerSummary(name: "sidecar", image: "example.invalid/sidecar:v1"),
            ],
            replicas: nil,
            selector: [],
            servicePorts: []
        )

        let result = RenderedKubernetesTranslationPreview.translate(successful([object]))

        XCTAssertEqual(result.errors.map(\.code), [.multipleContainersUnsupported])
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
    }

    func testResourceAdmissionFailureIsIndependentOfInputOrdering() {
        let api = pod(documentIndex: 2, name: "zeta", image: "example.invalid/zeta:v1")
        let worker = deployment(
            documentIndex: 1,
            name: "alpha",
            replicas: 2,
            selector: [label("app", "alpha")],
            image: "example.invalid/alpha:v1"
        )

        let first = RenderedKubernetesTranslationPreview.translate(successful([api, worker]))
        let second = RenderedKubernetesTranslationPreview.translate(successful([worker, api]))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.errors.map(\.code), [.resourceAdmissionUnavailable])
        XCTAssertNil(first.manifest)
        XCTAssertNil(first.manifestText)
    }

    func testRejectsMappedNamespaceNameCollision() {
        let result = RenderedKubernetesTranslationPreview.translate(
            successful([
                pod(documentIndex: 1, name: "a-b"),
                pod(documentIndex: 2, name: "b", namespace: "a"),
            ])
        )

        XCTAssertEqual(result.errors.map(\.code), [.identityCollision])
        XCTAssertTrue(result.errors[0].message.contains("a-b"))
        XCTAssertNil(result.manifest)
    }

    func testRejectsUnsupportedServiceProtocolBeforeExposureDiagnostic() {
        let result = RenderedKubernetesTranslationPreview.translate(
            successful([
                pod(documentIndex: 1, name: "api", labels: [label("app", "api")]),
                service(
                    documentIndex: 2,
                    name: "api",
                    selector: [label("app", "api")],
                    ports: [port(port: 80, targetPort: 80, protocolName: "SCTP")]
                ),
            ])
        )

        XCTAssertEqual(result.errors.map(\.code), [.unsupportedServiceProtocol])
        XCTAssertNil(result.manifest)
    }

    func testBoundsForgedSuccessfulSummaryCollections() {
        let objects = (1...65).map { index in
            pod(documentIndex: index, name: "workload-\(index)")
        }

        let result = RenderedKubernetesTranslationPreview.translate(successful(objects))

        XCTAssertEqual(result.errors.map(\.code), [.objectLimitExceeded])
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
    }

    func testBoundsForgedSuccessfulSummaryBytes() {
        let oversizedImage = String(
            repeating: "a",
            count: RenderedKubernetesTranslationPreview.maximumSummaryBytes + 1
        )

        let result = RenderedKubernetesTranslationPreview.translate(
            successful([
                pod(documentIndex: 1, name: "api", image: oversizedImage),
            ])
        )

        XCTAssertEqual(result.errors.map(\.code), [.summarySizeExceeded])
        XCTAssertNil(result.manifest)
        XCTAssertNil(result.manifestText)
    }

    private func successful(
        _ objects: [RenderedKubernetesObjectSummary]
    ) -> RenderedKubernetesImportResult {
        RenderedKubernetesImportResult(objects: objects, diagnostics: [])
    }

    private func pod(
        documentIndex: Int,
        name: String,
        namespace: String = "default",
        labels: [RenderedKubernetesKeyValueSummary] = [],
        image: String = "example.invalid/main:v1"
    ) -> RenderedKubernetesObjectSummary {
        RenderedKubernetesObjectSummary(
            documentIndex: documentIndex,
            apiVersion: "v1",
            kind: .pod,
            name: name,
            namespace: namespace,
            labels: labels,
            containers: [RenderedKubernetesContainerSummary(name: "main", image: image)],
            replicas: nil,
            selector: [],
            servicePorts: []
        )
    }

    private func deployment(
        documentIndex: Int,
        name: String,
        namespace: String = "default",
        replicas: Int,
        selector: [RenderedKubernetesKeyValueSummary],
        image: String
    ) -> RenderedKubernetesObjectSummary {
        RenderedKubernetesObjectSummary(
            documentIndex: documentIndex,
            apiVersion: "apps/v1",
            kind: .deployment,
            name: name,
            namespace: namespace,
            labels: [],
            containers: [RenderedKubernetesContainerSummary(name: "main", image: image)],
            replicas: replicas,
            selector: selector,
            servicePorts: []
        )
    }

    private func service(
        documentIndex: Int,
        name: String,
        namespace: String = "default",
        selector: [RenderedKubernetesKeyValueSummary],
        ports: [RenderedKubernetesServicePortSummary]? = nil
    ) -> RenderedKubernetesObjectSummary {
        RenderedKubernetesObjectSummary(
            documentIndex: documentIndex,
            apiVersion: "v1",
            kind: .service,
            name: name,
            namespace: namespace,
            labels: [],
            containers: [],
            replicas: nil,
            selector: selector,
            servicePorts: ports ?? [port(port: 80, targetPort: 80)]
        )
    }

    private func label(_ key: String, _ value: String) -> RenderedKubernetesKeyValueSummary {
        RenderedKubernetesKeyValueSummary(key: key, value: value)
    }

    private func port(
        port: Int,
        targetPort: Int,
        protocolName: String = "TCP"
    ) -> RenderedKubernetesServicePortSummary {
        RenderedKubernetesServicePortSummary(
            name: nil,
            port: port,
            targetPort: targetPort,
            protocolName: protocolName
        )
    }
}

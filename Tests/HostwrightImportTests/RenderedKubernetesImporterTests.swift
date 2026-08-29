import HostwrightImport
import XCTest

final class RenderedKubernetesImporterTests: XCTestCase {
    func testScansBoundedPodDeploymentAndServiceStreamIntoImmutableSummaries() throws {
        let result = RenderedKubernetesImporter.scan(
            """
            ---
            apiVersion: v1
            kind: Pod
            metadata:
              name: api
              namespace: production
              labels:
                app.kubernetes.io/name: api
                tier: backend
            spec:
              containers:
                - name: api
                  image: ghcr.io/example/api@sha256:abc123
              restartPolicy: OnFailure
            ---
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: worker
              labels:
                app: worker
            spec:
              replicas: 3
              selector:
                matchLabels:
                  app: worker
              template:
                metadata:
                  labels:
                    app: worker
                    track: stable
                spec:
                  containers:
                    - name: worker
                      image: ghcr.io/example/worker:v2
                  restartPolicy: Always
            ---
            apiVersion: v1
            kind: Service
            metadata:
              name: api
              namespace: production
            spec:
              selector:
                app.kubernetes.io/name: api
              type: ClusterIP
              ports:
                - name: http
                  port: 80
                  targetPort: 8080
                  protocol: TCP
                - name: metrics
                  port: 9090

            """
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.objects.count, 3)

        let pod = result.objects[0]
        XCTAssertEqual(pod.documentIndex, 1)
        XCTAssertEqual(pod.apiVersion, "v1")
        XCTAssertEqual(pod.kind, .pod)
        XCTAssertEqual(pod.name, "api")
        XCTAssertEqual(pod.namespace, "production")
        XCTAssertEqual(
            pod.labels,
            [
                RenderedKubernetesKeyValueSummary(key: "app.kubernetes.io/name", value: "api"),
                RenderedKubernetesKeyValueSummary(key: "tier", value: "backend"),
            ]
        )
        XCTAssertEqual(
            pod.containers,
            [RenderedKubernetesContainerSummary(name: "api", image: "ghcr.io/example/api@sha256:abc123")]
        )
        XCTAssertNil(pod.replicas)

        let deployment = result.objects[1]
        XCTAssertEqual(deployment.documentIndex, 2)
        XCTAssertEqual(deployment.apiVersion, "apps/v1")
        XCTAssertEqual(deployment.kind, .deployment)
        XCTAssertEqual(deployment.namespace, "default")
        XCTAssertEqual(deployment.replicas, 3)
        XCTAssertEqual(
            deployment.selector,
            [RenderedKubernetesKeyValueSummary(key: "app", value: "worker")]
        )
        XCTAssertEqual(
            deployment.containers,
            [RenderedKubernetesContainerSummary(name: "worker", image: "ghcr.io/example/worker:v2")]
        )

        let service = result.objects[2]
        XCTAssertEqual(service.documentIndex, 3)
        XCTAssertEqual(service.kind, .service)
        XCTAssertEqual(service.containers, [])
        XCTAssertEqual(
            service.selector,
            [RenderedKubernetesKeyValueSummary(key: "app.kubernetes.io/name", value: "api")]
        )
        XCTAssertEqual(
            service.servicePorts,
            [
                RenderedKubernetesServicePortSummary(
                    name: "http",
                    port: 80,
                    targetPort: 8_080,
                    protocolName: "TCP"
                ),
                RenderedKubernetesServicePortSummary(
                    name: "metrics",
                    port: 9_090,
                    targetPort: 9_090,
                    protocolName: "TCP"
                ),
            ]
        )
    }

    func testCommentsAndQuotedCommentMarkersRemainDeterministic() throws {
        let manifest = """
        # rendered locally
        apiVersion: v1 # core API
        kind: Pod
        metadata:
          name: comments
          labels:
            note: "safe-value"
        spec:
          containers:
            - name: main
              image: "example.invalid/image:v1" # quoted scalar followed by a comment

        """

        let first = RenderedKubernetesImporter.scan(manifest)
        let second = RenderedKubernetesImporter.scan(manifest)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(first.objects.first?.labels.first?.value, "safe-value")
        XCTAssertEqual(first.objects.first?.containers.first?.image, "example.invalid/image:v1")
    }

    func testRejectsUnsupportedAPIVersionKindAndFieldWithExactLocations() {
        let stream = """
        apiVersion: apps/v1beta1
        kind: Deployment
        metadata:
          name: legacy
        spec:
          replicas: 1
        ---
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: settings
        spec:
          containers:
            - name: ignored
              image: example.invalid/ignored:v1
        ---
        apiVersion: v1
        kind: Pod
        metadata:
          name: privileged
        spec:
          hostNetwork: true
          containers:
            - name: main
              image: example.invalid/main:v1

        """

        let result = RenderedKubernetesImporter.scan(stream)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.objects.isEmpty)
        XCTAssertEqual(result.diagnostics.count, 3)
        XCTAssertEqual(result.diagnostics[0].code, .unsupportedAPIVersion)
        XCTAssertEqual(result.diagnostics[0].documentIndex, 1)
        XCTAssertEqual(result.diagnostics[0].line, 1)
        XCTAssertEqual(result.diagnostics[0].path, "$.apiVersion")
        XCTAssertEqual(result.diagnostics[1].code, .unsupportedKind)
        XCTAssertEqual(result.diagnostics[1].documentIndex, 2)
        XCTAssertEqual(result.diagnostics[1].line, 9)
        XCTAssertEqual(result.diagnostics[1].path, "$.kind")
        XCTAssertEqual(result.diagnostics[2].code, .unsupportedField)
        XCTAssertEqual(result.diagnostics[2].documentIndex, 3)
        XCTAssertEqual(result.diagnostics[2].line, 22)
        XCTAssertEqual(result.diagnostics[2].path, "$.spec.hostNetwork")
        XCTAssertTrue(result.diagnostics.allSatisfy { $0.rendered.contains("document") })
    }

    func testRejectsAnchorsAliasesAndMergeKeysWithoutPartialAcceptance() {
        let anchor = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Pod
            metadata:
              name: &shared anchored
            spec:
              containers:
                - name: main
                  image: example.invalid/main:v1

            """
        )
        XCTAssertEqual(anchor.diagnostics.first?.code, .unsupportedYAMLFeature)
        XCTAssertEqual(anchor.diagnostics.first?.line, 4)
        XCTAssertEqual(anchor.diagnostics.first?.path, "$.metadata.name")

        let alias = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Pod
            metadata:
              name: aliased
              labels:
                app: *shared
            spec:
              containers:
                - name: main
                  image: example.invalid/main:v1

            """
        )
        XCTAssertEqual(alias.diagnostics.first?.code, .unsupportedYAMLFeature)
        XCTAssertEqual(alias.diagnostics.first?.line, 6)
        XCTAssertEqual(alias.diagnostics.first?.path, "$.metadata.labels.app")

        let merge = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Pod
            metadata:
              name: merged
              labels:
                <<: *shared
            spec:
              containers:
                - name: main
                  image: example.invalid/main:v1

            """
        )
        XCTAssertEqual(merge.diagnostics.first?.code, .unsupportedYAMLFeature)
        XCTAssertEqual(merge.diagnostics.first?.line, 6)
        XCTAssertEqual(merge.diagnostics.first?.path, "$.metadata.labels.<<")
        XCTAssertTrue(anchor.objects.isEmpty)
        XCTAssertTrue(alias.objects.isEmpty)
        XCTAssertTrue(merge.objects.isEmpty)
    }

    func testRejectsInlineFlowCollectionsWithoutPartialAcceptance() {
        let inlineMapping = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Pod
            metadata:
              name: inline
              labels: { app: api }
            spec:
              containers:
                - name: main
                  image: example.invalid/main:v1

            """
        )
        XCTAssertEqual(inlineMapping.diagnostics.first?.code, .unsupportedYAMLFeature)
        XCTAssertEqual(inlineMapping.diagnostics.first?.line, 5)
        XCTAssertEqual(inlineMapping.diagnostics.first?.path, "$.metadata.labels")

        let inlineSequence = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Service
            metadata:
              name: inline
            spec:
              selector:
                app: api
              ports: [80]

            """
        )
        XCTAssertEqual(inlineSequence.diagnostics.first?.code, .unsupportedYAMLFeature)
        XCTAssertEqual(inlineSequence.diagnostics.first?.line, 8)
        XCTAssertEqual(inlineSequence.diagnostics.first?.path, "$.spec.ports")
        XCTAssertTrue(inlineMapping.objects.isEmpty)
        XCTAssertTrue(inlineSequence.objects.isEmpty)
    }

    func testRejectsDuplicateKeysAndDuplicateObjectIdentity() {
        let duplicateKey = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Pod
            metadata:
              name: first
              name: second
            spec:
              containers:
                - name: main
                  image: example.invalid/main:v1

            """
        )
        XCTAssertEqual(duplicateKey.diagnostics.first?.code, .duplicateKey)
        XCTAssertEqual(duplicateKey.diagnostics.first?.line, 5)
        XCTAssertEqual(duplicateKey.diagnostics.first?.path, "$.metadata.name")

        let duplicateObject = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Pod
            metadata:
              name: same
              namespace: one
            spec:
              containers:
                - name: first
                  image: example.invalid/first:v1
            ---
            apiVersion: v1
            kind: Pod
            metadata:
              name: same
              namespace: one
            spec:
              containers:
                - name: second
                  image: example.invalid/second:v1

            """
        )
        XCTAssertEqual(duplicateObject.diagnostics.first?.code, .duplicateObject)
        XCTAssertEqual(duplicateObject.diagnostics.first?.documentIndex, 2)
        XCTAssertEqual(duplicateObject.diagnostics.first?.line, 14)
        XCTAssertEqual(duplicateObject.diagnostics.first?.path, "$.metadata.name")
        XCTAssertTrue(duplicateObject.objects.isEmpty)
    }

    func testRejectsEmptyDocumentsIncludingTrailingAndAdjacentMarkers() {
        let blank = RenderedKubernetesImporter.scan(" \n# comment\n")
        XCTAssertEqual(blank.diagnostics.first?.code, .emptyDocument)
        XCTAssertEqual(blank.diagnostics.first?.documentIndex, 1)

        let adjacent = RenderedKubernetesImporter.scan(
            """
            ---
            ---
            apiVersion: v1
            kind: Pod
            metadata:
              name: later
            spec:
              containers:
                - name: main
                  image: example.invalid/main:v1

            """
        )
        XCTAssertEqual(adjacent.diagnostics.first?.code, .emptyDocument)
        XCTAssertEqual(adjacent.diagnostics.first?.documentIndex, 1)
        XCTAssertEqual(adjacent.diagnostics.first?.line, 2)

        let trailing = RenderedKubernetesImporter.scan(validPod(name: "only") + "---\n")
        XCTAssertEqual(trailing.diagnostics.first?.code, .emptyDocument)
        XCTAssertEqual(trailing.diagnostics.first?.documentIndex, 2)
    }

    func testEnforcesInputDocumentLineDepthAndDocumentCountBounds() {
        let oversizedInput = String(
            repeating: "x",
            count: RenderedKubernetesImporter.maximumInputBytes + 1
        )
        XCTAssertEqual(
            RenderedKubernetesImporter.scan(oversizedInput).diagnostics.first?.code,
            .inputTooLarge
        )

        let oversizedDocument = "# " + String(
            repeating: "x",
            count: RenderedKubernetesImporter.maximumDocumentBytes
        )
        XCTAssertEqual(
            RenderedKubernetesImporter.scan(oversizedDocument).diagnostics.first?.code,
            .documentTooLarge
        )

        let tooLongLine = "apiVersion: \(String(repeating: "x", count: RenderedKubernetesImporter.maximumLineBytes))"
        XCTAssertEqual(
            RenderedKubernetesImporter.scan(tooLongLine).diagnostics.first?.code,
            .lineTooLong
        )

        let crlfLineAtNormalizedLimit = String(
            repeating: "x",
            count: RenderedKubernetesImporter.maximumLineBytes
        ) + "\r\n"
        XCTAssertEqual(
            RenderedKubernetesImporter.scan(crlfLineAtNormalizedLimit).diagnostics.first?.code,
            .lineTooLong
        )

        let tooManyLines = Array(
            repeating: "# bounded",
            count: RenderedKubernetesImporter.maximumLinesPerDocument + 1
        ).joined(separator: "\n")
        XCTAssertEqual(
            RenderedKubernetesImporter.scan(tooManyLines).diagnostics.first?.code,
            .tooManyLines
        )

        let tooManyNodes = (0..<RenderedKubernetesImporter.maximumNodesPerDocument)
            .map { "field\($0): value" }
            .joined(separator: "\n")
        XCTAssertEqual(
            RenderedKubernetesImporter.scan(tooManyNodes).diagnostics.first?.code,
            .nodeLimitExceeded
        )

        let oversizedScalar = "apiVersion: \(String(repeating: "v", count: RenderedKubernetesImporter.maximumScalarBytes + 1))"
        XCTAssertEqual(
            RenderedKubernetesImporter.scan(oversizedScalar).diagnostics.first?.code,
            .scalarTooLarge
        )

        var nestedLines = ["root:"]
        for depth in 1...RenderedKubernetesImporter.maximumDepth {
            nestedLines.append(String(repeating: "  ", count: depth) + "level\(depth):")
        }
        nestedLines.append(
            String(repeating: "  ", count: RenderedKubernetesImporter.maximumDepth + 1) + "value: terminal"
        )
        XCTAssertEqual(
            RenderedKubernetesImporter.scan(nestedLines.joined(separator: "\n")).diagnostics.first?.code,
            .depthExceeded
        )

        let tooManyDocuments = Array(
            repeating: validPod(name: "bounded") + "---\n",
            count: RenderedKubernetesImporter.maximumDocuments + 1
        ).joined()
        XCTAssertEqual(
            RenderedKubernetesImporter.scan(tooManyDocuments).diagnostics.first?.code,
            .tooManyDocuments
        )
    }

    func testRejectsDeploymentSelectorMismatchAndUnsafeServiceShape() {
        let deployment = RenderedKubernetesImporter.scan(
            """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: mismatch
            spec:
              selector:
                matchLabels:
                  app: expected
              template:
                metadata:
                  labels:
                    app: different
                spec:
                  containers:
                    - name: main
                      image: example.invalid/main:v1

            """
        )
        XCTAssertEqual(deployment.diagnostics.first?.code, .invalidValue)
        XCTAssertEqual(deployment.diagnostics.first?.path, "$.spec.template.metadata.labels.app")

        let laterMismatch = RenderedKubernetesImporter.scan(
            """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: later-mismatch
            spec:
              selector:
                matchLabels:
                  app: expected
                  role: api
              template:
                metadata:
                  labels:
                    app: expected
                    role: worker
                spec:
                  containers:
                    - name: main
                      image: example.invalid/main:v1

            """
        )
        XCTAssertEqual(laterMismatch.diagnostics.first?.code, .invalidValue)
        XCTAssertEqual(laterMismatch.diagnostics.first?.line, 14)
        XCTAssertEqual(laterMismatch.diagnostics.first?.path, "$.spec.template.metadata.labels.role")

        let service = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Service
            metadata:
              name: exposed
            spec:
              selector:
                app: api
              type: LoadBalancer
              ports:
                - port: 80

            """
        )
        XCTAssertEqual(service.diagnostics.first?.code, .invalidValue)
        XCTAssertEqual(service.diagnostics.first?.line, 8)
        XCTAssertEqual(service.diagnostics.first?.path, "$.spec.type")
    }

    func testRejectsFlowCollectionsOddIndentationAndTabs() {
        let flow = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Pod
            metadata: {name: flow}
            spec:
              containers:
                - name: main
                  image: example.invalid/main:v1

            """
        )
        XCTAssertEqual(flow.diagnostics.first?.code, .unsupportedYAMLFeature)
        XCTAssertEqual(flow.diagnostics.first?.path, "$.metadata")

        let odd = RenderedKubernetesImporter.scan(
            "apiVersion: v1\nkind: Pod\nmetadata:\n name: odd\n"
        )
        XCTAssertEqual(odd.diagnostics.first?.code, .invalidIndentation)
        XCTAssertEqual(odd.diagnostics.first?.line, 4)

        let tabbed = RenderedKubernetesImporter.scan(
            "apiVersion: v1\nkind: Pod\nmetadata:\n\tname: tabbed\n"
        )
        XCTAssertEqual(tabbed.diagnostics.first?.code, .unsupportedYAMLFeature)
        XCTAssertEqual(tabbed.diagnostics.first?.line, 4)
    }

    func testRejectsNonCanonicalNumbersAndDuplicateContainerAndPortNames() {
        let replicas = RenderedKubernetesImporter.scan(
            """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: leading-zero
            spec:
              replicas: 01
              selector:
                matchLabels:
                  app: worker
              template:
                metadata:
                  labels:
                    app: worker
                spec:
                  containers:
                    - name: worker
                      image: example.invalid/worker:v1

            """
        )
        XCTAssertEqual(replicas.diagnostics.first?.code, .invalidValue)
        XCTAssertEqual(replicas.diagnostics.first?.path, "$.spec.replicas")

        let containers = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Pod
            metadata:
              name: duplicate-containers
            spec:
              containers:
                - name: main
                  image: example.invalid/one:v1
                - name: main
                  image: example.invalid/two:v1

            """
        )
        XCTAssertEqual(containers.diagnostics.first?.code, .invalidValue)
        XCTAssertEqual(containers.diagnostics.first?.path, "$.spec.containers[1].name")

        let ports = RenderedKubernetesImporter.scan(
            """
            apiVersion: v1
            kind: Service
            metadata:
              name: duplicate-ports
            spec:
              selector:
                app: api
              ports:
                - name: http
                  port: 80
                - name: http
                  port: 81

            """
        )
        XCTAssertEqual(ports.diagnostics.first?.code, .invalidValue)
        XCTAssertEqual(ports.diagnostics.first?.path, "$.spec.ports[1].name")
    }

    private func validPod(name: String) -> String {
        """
        apiVersion: v1
        kind: Pod
        metadata:
          name: \(name)
        spec:
          containers:
            - name: main
              image: example.invalid/main:v1

        """ + "\n"
    }
}

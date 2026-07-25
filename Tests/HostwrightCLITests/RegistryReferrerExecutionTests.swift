import Foundation
import HostwrightCore
import HostwrightRegistry
import HostwrightState
@testable import HostwrightCLI
import XCTest

final class RegistryReferrerExecutionTests: XCTestCase {
    func testOfflineFetchUsesOnlyVerifiedCache() throws {
        let fixture = try makeFixture(
            endpoint: "registry.example.com",
            repository: "team/app"
        )
        let store = try makeStore()
        defer { removeStore(store) }
        let record = try store.ociReferrers.saveGraph(
            fixture.graph,
            observedAt: "2026-07-24T18:00:00Z"
        )
        let transport = ReferrerExecutionTransport([])
        var environment = CLIEnvironment.live
        environment.registryTransport = { transport }

        let result = HostwrightCLI.run(
            arguments: [
                "registry", "referrers", "fetch",
                "registry.example.com",
                "--repository", "team/app",
                "--subject", fixture.subject.canonicalValue,
                "--offline",
                "--state-db", store.path,
                "--json"
            ],
            environment: environment
        )

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(
            result.standardOutput.contains(
                #""discoveryID":"\#(record.id)""#
            )
        )
        XCTAssertTrue(result.standardOutput.contains(#""offline":true"#))
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testOfflineDiscoverDoesNotSubstituteFilteredCache()
        throws
    {
        let fixture = try makeFixture(
            endpoint: "registry.example.com",
            repository: "team/app"
        )
        let store = try makeStore()
        defer { removeStore(store) }
        let unfiltered = try store.ociReferrers.saveGraph(
            fixture.graph,
            observedAt: "2026-07-24T18:00:00Z"
        )
        let filteredDiscovery = OCIReferrerDiscoveryResult(
            endpoint: fixture.graph.discovery.endpoint,
            repository: fixture.graph.discovery.repository,
            subjectDigest: fixture.subject,
            artifactType: fixture.descriptor.artifactType,
            mode: .native,
            serverFilterApplied: true,
            pageCount: 1,
            descriptors: fixture.graph.verifiedReferrers,
            etag: #""filtered-v1""#
        )
        _ = try store.ociReferrers.saveGraph(
            OCIReferrerGraph(
                discovery: filteredDiscovery,
                verifiedReferrers: fixture.graph.verifiedReferrers,
                objects: fixture.graph.objects
            ),
            observedAt: "2026-07-24T18:01:00Z"
        )
        let transport = ReferrerExecutionTransport([])
        var environment = CLIEnvironment.live
        environment.registryTransport = { transport }

        let result = HostwrightCLI.run(
            arguments: [
                "registry", "referrers", "discover",
                "registry.example.com",
                "--repository", "team/app",
                "--subject", fixture.subject.canonicalValue,
                "--offline",
                "--state-db", store.path,
                "--json"
            ],
            environment: environment
        )

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(
            result.standardOutput.contains(
                #""discoveryID":"\#(unfiltered.id)""#
            )
        )
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testDurablePublishPersistsIntentObservationAndOwnership()
        throws
    {
        let source = try makeFixture(
            endpoint: "source.example.com",
            repository: "source/app"
        )
        let store = try makeStore()
        defer { removeStore(store) }
        let sourceRecord = try store.ociReferrers.saveGraph(
            source.graph,
            observedAt: "2026-07-24T18:00:00Z"
        )
        let finalIndex = indexData([source.descriptor])
        let transport = ReferrerExecutionTransport([
            .success(indexResponse([])),
            .success(response(404)),
            .success(
                response(
                    202,
                    headers: [
                        "location":
                            "/v2/team/copy/blobs/uploads/session-1"
                    ]
                )
            ),
            .success(
                response(
                    201,
                    headers: [
                        "docker-content-digest":
                            source.blobDigest.canonicalValue
                    ]
                )
            ),
            .success(
                response(
                    200,
                    headers: [
                        "docker-content-digest":
                            source.blobDigest.canonicalValue,
                        "content-length": String(source.blob.count)
                    ]
                )
            ),
            .success(response(404)),
            .success(
                response(
                    201,
                    headers: [
                        "docker-content-digest":
                            source.manifestDigest.canonicalValue,
                        "oci-subject":
                            source.subject.canonicalValue
                    ]
                )
            ),
            .success(manifestResponse(source)),
            .success(
                response(
                    200,
                    body: finalIndex,
                    contentType: OCIReferrerIndex.mediaType
                )
            )
        ])
        let coordinator = makeCoordinator(
            store: store,
            transport: transport
        )

        let result = try coordinator.publish(
            discoveryID: sourceRecord.id,
            targetServer: "target.example.com",
            targetRepository: "team/copy"
        )

        XCTAssertTrue(result.standardOutput.contains(#""status":"verified""#))
        let groups = try store.operationGroups.loadAll().filter {
            $0.groupKind ==
                RegistryReferrerMutationCoordinator.groupKind
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].status, .succeeded)
        XCTAssertEqual(groups[0].checkpoint, "state-observed")
        let targetRecord = try XCTUnwrap(
            store.ociReferrers.latestDiscovery(
                endpoint: "https://target.example.com",
                repository: "team/copy",
                subjectDigest: source.subject.canonicalValue,
                artifactType: nil
            )
        )
        XCTAssertNotEqual(targetRecord.id, sourceRecord.id)
        let publication = try XCTUnwrap(
            store.ociReferrers.loadPublication(
                endpoint: "https://target.example.com",
                repository: "team/copy",
                subjectDigest: source.subject.canonicalValue,
                referrerDigest:
                    source.manifestDigest.canonicalValue
            )
        )
        XCTAssertEqual(publication.operationGroupID, groups[0].id)
        XCTAssertTrue(publication.cleanupEligible)
    }

    func testInterruptedPublishResumesExactPersistedIntent() throws {
        let source = try makeFixture(
            endpoint: "source.example.com",
            repository: "source/app"
        )
        let store = try makeStore()
        defer { removeStore(store) }
        let sourceRecord = try store.ociReferrers.saveGraph(
            source.graph,
            observedAt: "2026-07-24T18:00:00Z"
        )
        let transport = ReferrerExecutionTransport([
            .success(indexResponse([])),
            .success(response(404)),
            .success(
                response(
                    202,
                    headers: [
                        "location":
                            "/v2/team/copy/blobs/uploads/session-failed"
                    ]
                )
            ),
            .failure(RegistryTransportError.transportFailed),
            .success(response(202))
        ])
        let coordinator = makeCoordinator(
            store: store,
            transport: transport
        )

        XCTAssertThrowsError(
            try coordinator.publish(
                discoveryID: sourceRecord.id,
                targetServer: "target.example.com",
                targetRepository: "team/copy"
            )
        )
        let interrupted = try XCTUnwrap(
            store.operationGroups.loadAll().first {
                $0.groupKind ==
                    RegistryReferrerMutationCoordinator.groupKind
            }
        )
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(interrupted.checkpoint, "recovery-required")

        transport.append([
            .success(indexResponse([])),
            .success(response(404)),
            .success(
                response(
                    202,
                    headers: [
                        "location":
                            "/v2/team/copy/blobs/uploads/session-resume"
                    ]
                )
            ),
            .success(
                response(
                    201,
                    headers: [
                        "docker-content-digest":
                            source.blobDigest.canonicalValue
                    ]
                )
            ),
            .success(
                response(
                    200,
                    headers: [
                        "docker-content-digest":
                            source.blobDigest.canonicalValue,
                        "content-length": String(source.blob.count)
                    ]
                )
            ),
            .success(response(404)),
            .success(
                response(
                    201,
                    headers: [
                        "docker-content-digest":
                            source.manifestDigest.canonicalValue,
                        "oci-subject":
                            source.subject.canonicalValue
                    ]
                )
            ),
            .success(manifestResponse(source)),
            .success(
                response(
                    200,
                    body: indexData([source.descriptor]),
                    contentType: OCIReferrerIndex.mediaType
                )
            )
        ])

        let resumed = try coordinator.resume(
            groupID: interrupted.id,
            confirmationPlanSHA256: interrupted.planHash
        )

        XCTAssertTrue(
            resumed.standardOutput.contains(#""status":"verified""#)
        )
        XCTAssertEqual(
            try store.operationGroups.load(id: interrupted.id)?.status,
            .succeeded
        )
    }

    private func makeCoordinator(
        store: SQLiteStateStore,
        transport: ReferrerExecutionTransport
    ) -> RegistryReferrerMutationCoordinator {
        RegistryReferrerMutationCoordinator(
            store: store,
            client: OCIReferrerRegistryClient(
                authenticationClient: RegistryAuthenticationClient(
                    transport: transport,
                    now: {
                        Date(timeIntervalSince1970: 1_753_380_000)
                    }
                )
            ),
            output: .json,
            credentialResolver: { _ in
                RegistryReferrerCredentialResolution(
                    credential: nil,
                    kind: .basic
                )
            },
            now: {
                Date(timeIntervalSince1970: 1_753_380_000)
            }
        )
    }

    private func makeStore() throws -> SQLiteStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-referrer-cli-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let store = SQLiteStateStore(
            path: directory.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        return store
    }

    private func removeStore(_ store: SQLiteStateStore) {
        let directory = URL(fileURLWithPath: store.path)
            .deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFixture(
        endpoint: String,
        repository: String
    ) throws -> ReferrerExecutionFixture {
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "1", count: 64)
        )
        let blob = Data("opaque-payload".utf8)
        let blobDigest = try OCIContentDigest.sha256(of: blob)
        let manifest = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType":
                    OCIReferrerDescriptor.manifestMediaType,
                "artifactType":
                    "application/vnd.example.opaque.v1",
                "subject": [
                    "mediaType":
                        OCIReferrerDescriptor.manifestMediaType,
                    "digest": subject.canonicalValue,
                    "size": 1
                ],
                "config": [
                    "mediaType": "application/vnd.example.opaque.v1",
                    "digest": blobDigest.canonicalValue,
                    "size": blob.count
                ],
                "layers": []
            ],
            options: [.sortedKeys]
        )
        let manifestDigest = try OCIContentDigest.sha256(of: manifest)
        let child = try OCIContentDescriptor(
            mediaType: "application/vnd.example.opaque.v1",
            digest: blobDigest,
            size: blob.count
        )
        let descriptor = try OCIReferrerDescriptor(
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            digest: manifestDigest,
            size: manifest.count,
            artifactType: OCIArtifactType(
                "application/vnd.example.opaque.v1"
            ),
            annotations: [:]
        )
        let discovery = OCIReferrerDiscoveryResult(
            endpoint: try RegistryEndpoint(endpoint),
            repository: try OCIRepositoryName(repository),
            subjectDigest: subject,
            artifactType: nil,
            mode: .native,
            serverFilterApplied: false,
            pageCount: 1,
            descriptors: [descriptor],
            etag: nil
        )
        return ReferrerExecutionFixture(
            subject: subject,
            blob: blob,
            blobDigest: blobDigest,
            manifest: manifest,
            manifestDigest: manifestDigest,
            descriptor: descriptor,
            graph: try OCIReferrerGraph(
                discovery: discovery,
                verifiedReferrers: [descriptor],
                objects: [
                    OCIReferrerFetchedObject(
                        digest: manifestDigest,
                        mediaType: descriptor.mediaType,
                        size: manifest.count,
                        kind: .manifest,
                        payload: manifest,
                        childDescriptors: [child]
                    ),
                    OCIReferrerFetchedObject(
                        digest: blobDigest,
                        mediaType: child.mediaType,
                        size: blob.count,
                        kind: .blob,
                        payload: blob,
                        childDescriptors: []
                    )
                ]
            )
        )
    }

    private func manifestResponse(
        _ fixture: ReferrerExecutionFixture
    ) -> RegistryTransportResponse {
        response(
            200,
            body: fixture.manifest,
            contentType: OCIReferrerDescriptor.manifestMediaType,
            headers: [
                "docker-content-digest":
                    fixture.manifestDigest.canonicalValue
            ]
        )
    }

    private func indexResponse(
        _ descriptors: [OCIReferrerDescriptor]
    ) -> RegistryTransportResponse {
        response(
            200,
            body: indexData(descriptors),
            contentType: OCIReferrerIndex.mediaType
        )
    }

    private func indexData(
        _ descriptors: [OCIReferrerDescriptor]
    ) -> Data {
        try! JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType": OCIReferrerIndex.mediaType,
                "manifests": descriptors.map {
                    [
                        "mediaType": $0.mediaType,
                        "digest": $0.digest.canonicalValue,
                        "size": $0.size,
                        "artifactType": $0.artifactType!.value
                    ] as [String: Any]
                }
            ],
            options: [.sortedKeys]
        )
    }

    private func response(
        _ status: Int,
        body: Data = Data(),
        contentType: String? = nil,
        headers: [String: String] = [:]
    ) -> RegistryTransportResponse {
        var values = headers
        if let contentType {
            values["content-type"] = contentType
        }
        return RegistryTransportResponse(
            statusCode: status,
            headers: values,
            body: body
        )
    }
}

private struct ReferrerExecutionFixture {
    let subject: OCIContentDigest
    let blob: Data
    let blobDigest: OCIContentDigest
    let manifest: Data
    let manifestDigest: OCIContentDigest
    let descriptor: OCIReferrerDescriptor
    let graph: OCIReferrerGraph
}

private final class ReferrerExecutionTransport:
    RegistrySynchronousHTTPTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var responses:
        [Result<RegistryTransportResponse, Error>]
    private var recorded: [RegistryTransportRequest] = []

    init(
        _ responses: [Result<RegistryTransportResponse, Error>]
    ) {
        self.responses = responses
    }

    var requests: [RegistryTransportRequest] {
        lock.withLock { recorded }
    }

    func append(
        _ values: [Result<RegistryTransportResponse, Error>]
    ) {
        lock.withLock { responses.append(contentsOf: values) }
    }

    func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        try lock.withLock {
            recorded.append(request)
            guard !responses.isEmpty else {
                throw RegistryTransportError.transportFailed
            }
            return try responses.removeFirst().get()
        }
    }
}

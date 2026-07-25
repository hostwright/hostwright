import Foundation

public struct OCIReferrerPublishResult: Equatable, Sendable {
    public let endpoint: RegistryEndpoint
    public let repository: OCIRepositoryName
    public let subjectDigest: OCIContentDigest
    public let mode: OCIReferrerDiscoveryMode
    public let publishedDigests: [OCIContentDigest]
    public let reusedDigests: [OCIContentDigest]
    public let verifiedReferrers: [OCIReferrerDescriptor]
}

public extension OCIReferrerRegistryClient {
    func publish(
        _ graph: OCIReferrerGraph,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        credential: RegistryCredential? = nil,
        credentialKind: RegistryCredentialAuthorizationKind = .basic,
        cancellation: RegistryTransportCancellation =
            RegistryTransportCancellation()
    ) throws -> OCIReferrerPublishResult {
        let preflight = try discover(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: graph.discovery.subjectDigest,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation
        )
        if preflight.mode == .tagFallback, preflight.etag == nil {
            throw OCIReferrerRegistryError.fallbackWriteUnavailable
        }
        let publisher = try OCIReferrerGraphPublisher(
            authenticationClient: authenticationClient,
            endpoint: endpoint,
            repository: repository,
            subjectDigest: graph.discovery.subjectDigest,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation,
            nativeReferrers: preflight.mode == .native
        )
        let ordered = try publisher.orderedObjects(graph)
        var published: [OCIContentDigest] = []
        var reused: [OCIContentDigest] = []
        let roots = Dictionary(
            uniqueKeysWithValues: graph.verifiedReferrers.map {
                ($0.digest, $0)
            }
        )
        for object in ordered {
            let created = try publisher.publish(
                object,
                rootDescriptor: roots[object.digest]
            )
            if created {
                published.append(object.digest)
            } else {
                reused.append(object.digest)
            }
        }

        let finalMode: OCIReferrerDiscoveryMode
        if preflight.mode == .native {
            finalMode = .native
        } else {
            try publisher.updateFallbackIndex(
                existing: preflight.descriptors,
                additions: graph.verifiedReferrers,
                etag: preflight.etag,
                create: preflight.mode == .tagFallbackEmpty
            )
            finalMode = .tagFallback
        }
        let observed = try discover(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: graph.discovery.subjectDigest,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation
        )
        let observedByDigest = Dictionary(
            uniqueKeysWithValues: observed.descriptors.map {
                ($0.digest, $0)
            }
        )
        guard graph.verifiedReferrers.allSatisfy({
            observedByDigest[$0.digest] == $0
        }) else {
            if published.isEmpty {
                throw OCIReferrerRegistryError.invalidResponse
            }
            throw OCIReferrerRegistryError.partialEffect
        }
        return OCIReferrerPublishResult(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: graph.discovery.subjectDigest,
            mode: finalMode,
            publishedDigests: published,
            reusedDigests: reused,
            verifiedReferrers: graph.verifiedReferrers
        )
    }
}

private struct OCIReferrerGraphPublisher {
    let authenticationClient: RegistryAuthenticationClient
    let endpoint: RegistryEndpoint
    let repository: OCIRepositoryName
    let subjectDigest: OCIContentDigest
    let credential: RegistryCredential?
    let credentialKind: RegistryCredentialAuthorizationKind
    let cancellation: RegistryTransportCancellation
    let nativeReferrers: Bool
    let scope: RegistryAccessScopeSet

    init(
        authenticationClient: RegistryAuthenticationClient,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subjectDigest: OCIContentDigest,
        credential: RegistryCredential?,
        credentialKind: RegistryCredentialAuthorizationKind,
        cancellation: RegistryTransportCancellation,
        nativeReferrers: Bool
    ) throws {
        self.authenticationClient = authenticationClient
        self.endpoint = endpoint
        self.repository = repository
        self.subjectDigest = subjectDigest
        self.credential = credential
        self.credentialKind = credentialKind
        self.cancellation = cancellation
        self.nativeReferrers = nativeReferrers
        do {
            scope = try RegistryAccessScopeSet([
                RegistryAccessScope(
                    resourceType: .repository,
                    name: repository.value,
                    actions: [.pull, .push]
                )
            ])
        } catch {
            throw OCIReferrerRegistryError.invalidRequest
        }
    }

    func orderedObjects(
        _ graph: OCIReferrerGraph
    ) throws -> [OCIReferrerFetchedObject] {
        let byDigest = Dictionary(
            uniqueKeysWithValues: graph.objects.map {
                ($0.digest, $0)
            }
        )
        var visiting = Set<OCIContentDigest>()
        var visited = Set<OCIContentDigest>()
        var ordered: [OCIReferrerFetchedObject] = []

        func visit(_ digest: OCIContentDigest) throws {
            if visited.contains(digest) { return }
            guard visiting.insert(digest).inserted,
                  let object = byDigest[digest] else {
                throw OCIReferrerRegistryError.invalidGraph
            }
            for child in object.childDescriptors {
                guard let value = byDigest[child.digest],
                      value.mediaType == child.mediaType,
                      value.size == child.size else {
                    throw OCIReferrerRegistryError.invalidGraph
                }
                try visit(child.digest)
            }
            visiting.remove(digest)
            visited.insert(digest)
            ordered.append(object)
        }
        for root in graph.verifiedReferrers.sorted(by: {
            $0.digest.canonicalValue < $1.digest.canonicalValue
        }) {
            try visit(root.digest)
        }
        guard visited.count == graph.objects.count else {
            throw OCIReferrerRegistryError.invalidGraph
        }
        return ordered
    }

    func publish(
        _ object: OCIReferrerFetchedObject,
        rootDescriptor: OCIReferrerDescriptor?
    ) throws -> Bool {
        let url = try objectURL(
            digest: object.digest,
            kind: object.kind
        )
        let head = try send(
            RegistryTransportRequest(
                url: url,
                method: .head,
                headers: ["Accept": object.mediaType]
            ),
            cancellation: cancellation
        )
        if head.statusCode == 200 {
            try validateHead(head, object: object)
            if object.kind != .blob {
                try observeManifest(
                    object,
                    rootDescriptor: rootDescriptor
                )
            }
            return false
        }
        guard head.statusCode == 404 else {
            throw OCIReferrerRegistryError.unexpectedStatus(
                head.statusCode
            )
        }
        if object.kind == .blob {
            try uploadBlob(object)
        } else {
            let response = try send(
                RegistryTransportRequest(
                    url: url,
                    method: .put,
                    headers: ["Content-Type": object.mediaType],
                    body: object.payload
                ),
                cancellation: cancellation
            )
            guard response.statusCode == 201 ||
                    response.statusCode == 202,
                  header(
                      "docker-content-digest",
                      response: response
                  ) == object.digest.canonicalValue else {
                throw OCIReferrerRegistryError.partialEffect
            }
            if let rootDescriptor, nativeReferrers {
                guard header(
                    "oci-subject",
                    response: response
                ) == subjectDigest.canonicalValue else {
                    throw OCIReferrerRegistryError.partialEffect
                }
                guard rootDescriptor.digest == object.digest else {
                    throw OCIReferrerRegistryError.invalidGraph
                }
            }
            try observeManifest(
                object,
                rootDescriptor: rootDescriptor
            )
        }
        return true
    }

    func updateFallbackIndex(
        existing: [OCIReferrerDescriptor],
        additions: [OCIReferrerDescriptor],
        etag: String?,
        create: Bool
    ) throws {
        guard create ? etag == nil : etag != nil else {
            throw OCIReferrerRegistryError.fallbackWriteUnavailable
        }
        var byDigest = Dictionary(
            uniqueKeysWithValues: existing.map {
                ($0.digest, $0)
            }
        )
        for descriptor in additions {
            if let current = byDigest[descriptor.digest],
               current != descriptor {
                throw OCIReferrerRegistryError.invalidResponse
            }
            byDigest[descriptor.digest] = descriptor
        }
        let body = try encodeIndex(
            byDigest.values.sorted {
                $0.digest.canonicalValue < $1.digest.canonicalValue
            }
        )
        var headers = ["Content-Type": OCIReferrerIndex.mediaType]
        if let etag {
            headers["If-Match"] = etag
        } else {
            headers["If-None-Match"] = "*"
        }
        let url = try fallbackIndexURL()
        let response = try send(
            RegistryTransportRequest(
                url: url,
                method: .put,
                headers: headers,
                body: body
            ),
            cancellation: cancellation
        )
        guard response.statusCode == 201 ||
                response.statusCode == 202 else {
            throw OCIReferrerRegistryError.partialEffect
        }
        let observed = try send(
            RegistryTransportRequest(
                url: url,
                method: .get,
                headers: ["Accept": OCIReferrerIndex.mediaType]
            ),
            cancellation: cancellation
        )
        guard observed.statusCode == 200 else {
            throw OCIReferrerRegistryError.partialEffect
        }
        let index: OCIReferrerIndex
        do {
            index = try OCIReferrerIndex.parse(
                observed.body,
                subjectDigest: subjectDigest
            )
        } catch {
            throw OCIReferrerRegistryError.partialEffect
        }
        let observedByDigest = Dictionary(
            uniqueKeysWithValues: index.descriptors.map {
                ($0.digest, $0)
            }
        )
        guard byDigest.values.allSatisfy({
            observedByDigest[$0.digest] == $0
        }) else {
            throw OCIReferrerRegistryError.partialEffect
        }
    }

    private func uploadBlob(
        _ object: OCIReferrerFetchedObject
    ) throws {
        let startURL = try uploadStartURL()
        let started = try send(
            RegistryTransportRequest(
                url: startURL,
                method: .post,
                headers: ["Content-Length": "0"]
            ),
            cancellation: cancellation
        )
        guard started.statusCode == 202,
              let location = header(
                  "location",
                  response: started
              ),
              let sessionURL = URL(
                  string: location,
                  relativeTo: startURL
              )?.absoluteURL else {
            throw OCIReferrerRegistryError.invalidResponse
        }
        let validatedSession: URL
        do {
            validatedSession = try validateUploadLocation(
                sessionURL
            )
        } catch {
            throw OCIReferrerRegistryError.unsafeUploadLocation
        }
        let finalURL = try appendDigest(
            object.digest,
            to: validatedSession
        )
        do {
            let finalized = try send(
                RegistryTransportRequest(
                    url: finalURL,
                    method: .put,
                    headers: [
                        "Content-Type": "application/octet-stream"
                    ],
                    body: object.payload
                ),
                cancellation: cancellation
            )
            guard finalized.statusCode == 201,
                  header(
                      "docker-content-digest",
                      response: finalized
                  ) == object.digest.canonicalValue else {
                throw OCIReferrerRegistryError.partialEffect
            }
        } catch {
            let cleanupSucceeded = cancelUpload(validatedSession)
            if !cleanupSucceeded {
                throw OCIReferrerRegistryError.partialEffect
            }
            throw error
        }
        let observed = try send(
            RegistryTransportRequest(
                url: try objectURL(
                    digest: object.digest,
                    kind: .blob
                ),
                method: .head
            ),
            cancellation: cancellation
        )
        guard observed.statusCode == 200 else {
            throw OCIReferrerRegistryError.partialEffect
        }
        try validateHead(observed, object: object)
    }

    private func observeManifest(
        _ object: OCIReferrerFetchedObject,
        rootDescriptor: OCIReferrerDescriptor?
    ) throws {
        let response = try send(
            RegistryTransportRequest(
                url: try objectURL(
                    digest: object.digest,
                    kind: object.kind
                ),
                method: .get,
                headers: ["Accept": object.mediaType]
            ),
            cancellation: cancellation
        )
        guard response.statusCode == 200,
              response.body.count == object.size,
              try object.digest.matches(response.body),
              response.body == object.payload,
              header(
                  "docker-content-digest",
                  response: response
              ) == object.digest.canonicalValue else {
            throw OCIReferrerRegistryError.partialEffect
        }
        if let rootDescriptor {
            let document: OCIParsedDocument
            do {
                document = try OCIParsedDocument.parse(
                    response.body
                )
            } catch {
                throw OCIReferrerRegistryError.partialEffect
            }
            guard document.subject?.digest == subjectDigest,
                  document.effectiveArtifactType ==
                    rootDescriptor.artifactType else {
                throw OCIReferrerRegistryError.partialEffect
            }
        }
    }

    private func validateHead(
        _ response: RegistryTransportResponse,
        object: OCIReferrerFetchedObject
    ) throws {
        guard header(
            "docker-content-digest",
            response: response
        ) == object.digest.canonicalValue,
        let lengthValue = header(
            "content-length",
            response: response
        ),
        Int(lengthValue) == object.size else {
            throw OCIReferrerRegistryError.invalidResponse
        }
    }

    private func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        do {
            return try authenticationClient.sendAuthorized(
                request,
                endpoint: endpoint,
                requestedScopes: scope,
                credential: credential,
                credentialKind: credentialKind,
                cancellation: cancellation
            ).response
        } catch let error as RegistryAuthenticationError {
            switch error {
            case .cancelled:
                throw OCIReferrerRegistryError.cancelled
            case .transportUnavailable:
                throw OCIReferrerRegistryError.transportUnavailable
            case .credentialUnavailable, .authenticationDenied, .scopeDenied:
                throw OCIReferrerRegistryError.authorizationFailed
            case .invalidRequest:
                throw OCIReferrerRegistryError.invalidRequest
            case .invalidResponse:
                throw OCIReferrerRegistryError.invalidResponse
            }
        }
    }

    private func cancelUpload(_ url: URL) -> Bool {
        do {
            let response = try send(
                RegistryTransportRequest(
                    url: url,
                    method: .delete
                ),
                cancellation: RegistryTransportCancellation()
            )
            return response.statusCode == 204 ||
                response.statusCode == 202 ||
                response.statusCode == 404
        } catch {
            return false
        }
    }

    private func validateUploadLocation(
        _ url: URL
    ) throws -> URL {
        let prefix = "/v2/\(repository.value)/blobs/uploads/"
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() ==
                endpoint.url.host?.lowercased(),
              (url.port ?? 443) == (endpoint.url.port ?? 443),
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.path.hasPrefix(prefix),
              url.absoluteString.utf8.count <= 8_192 else {
            throw OCIReferrerRegistryError.unsafeUploadLocation
        }
        return url
    }

    private func appendDigest(
        _ digest: OCIContentDigest,
        to url: URL
    ) throws -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw OCIReferrerRegistryError.unsafeUploadLocation
        }
        var query = components.queryItems ?? []
        guard !query.contains(where: { $0.name == "digest" }) else {
            throw OCIReferrerRegistryError.unsafeUploadLocation
        }
        query.append(
            URLQueryItem(
                name: "digest",
                value: digest.canonicalValue
            )
        )
        components.queryItems = query
        guard let value = components.url else {
            throw OCIReferrerRegistryError.unsafeUploadLocation
        }
        return value
    }

    private func uploadStartURL() throws -> URL {
        guard let url = URL(
            string: endpoint.canonicalURLString +
                "/v2/\(repository.value)/blobs/uploads/"
        ) else {
            throw OCIReferrerRegistryError.invalidRequest
        }
        return url
    }

    private func objectURL(
        digest: OCIContentDigest,
        kind: OCIReferrerObjectKind
    ) throws -> URL {
        let collection = kind == .blob ? "blobs" : "manifests"
        guard let url = URL(
            string: endpoint.canonicalURLString +
                "/v2/\(repository.value)/\(collection)/" +
                digest.canonicalValue
        ) else {
            throw OCIReferrerRegistryError.invalidRequest
        }
        return url
    }

    private func fallbackIndexURL() throws -> URL {
        guard let fallbackTag = subjectDigest.exactReferrersTag else {
            throw OCIReferrerRegistryError.fallbackDigestUnsupported
        }
        guard let url = URL(
            string: endpoint.canonicalURLString +
                "/v2/\(repository.value)/manifests/" +
                fallbackTag
        ) else {
            throw OCIReferrerRegistryError.invalidRequest
        }
        return url
    }

    private func encodeIndex(
        _ descriptors: [OCIReferrerDescriptor]
    ) throws -> Data {
        let manifests: [[String: Any]] = descriptors.map { descriptor in
            var value: [String: Any] = [
                "mediaType": descriptor.mediaType,
                "digest": descriptor.digest.canonicalValue,
                "size": descriptor.size
            ]
            if let artifactType = descriptor.artifactType {
                value["artifactType"] = artifactType.value
            }
            if !descriptor.annotations.isEmpty {
                value["annotations"] = descriptor.annotations
            }
            return value
        }
        let data = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "mediaType": OCIReferrerIndex.mediaType,
                "manifests": manifests
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= OCIReferrerLimits.maximumObjectBytes else {
            throw OCIReferrerRegistryError.limitExceeded
        }
        return data
    }

    private func header(
        _ name: String,
        response: RegistryTransportResponse
    ) -> String? {
        response.headers.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

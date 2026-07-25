import Foundation

public struct OCIReferrerRemovalResult: Equatable, Sendable {
    public let endpoint: RegistryEndpoint
    public let repository: OCIRepositoryName
    public let subjectDigest: OCIContentDigest
    public let referrerDigest: OCIContentDigest
    public let mode: OCIReferrerDiscoveryMode
    public let removed: Bool
}

public extension OCIReferrerRegistryClient {
    func removeOwnedReferrer(
        graph: OCIReferrerGraph,
        referrerDigest: OCIContentDigest,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        ownershipProofSHA256: String,
        credential: RegistryCredential? = nil,
        credentialKind: RegistryCredentialAuthorizationKind = .basic,
        cancellation: RegistryTransportCancellation =
            RegistryTransportCancellation()
    ) throws -> OCIReferrerRemovalResult {
        guard ownershipProofSHA256.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil else {
            throw OCIReferrerRegistryError.ownershipUnverified
        }
        guard let descriptor = graph.verifiedReferrers.first(
            where: { $0.digest == referrerDigest }
        ),
        let root = graph.objects.first(
            where: { $0.digest == referrerDigest }
        ),
        root.kind != .blob,
        descriptor.mediaType == root.mediaType,
        descriptor.size == root.size else {
            throw OCIReferrerRegistryError.invalidGraph
        }

        let discovery = try discover(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: graph.discovery.subjectDigest,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation
        )
        let remover = try OCIReferrerRemover(
            authenticationClient: authenticationClient,
            endpoint: endpoint,
            repository: repository,
            subjectDigest: graph.discovery.subjectDigest,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation
        )
        guard let observedDescriptor = discovery.descriptors.first(
            where: { $0.digest == referrerDigest }
        ) else {
            guard try remover.verifyManifestIfPresent(
                root,
                descriptor: descriptor
            ) else {
                return OCIReferrerRemovalResult(
                    endpoint: endpoint,
                    repository: repository,
                    subjectDigest: graph.discovery.subjectDigest,
                    referrerDigest: referrerDigest,
                    mode: discovery.mode,
                    removed: false
                )
            }
            try remover.deleteManifest(
                referrerDigest,
                expectedStatusMode: discovery.mode
            )
            return OCIReferrerRemovalResult(
                endpoint: endpoint,
                repository: repository,
                subjectDigest: graph.discovery.subjectDigest,
                referrerDigest: referrerDigest,
                mode: discovery.mode == .native
                    ? .native : .tagFallback,
                removed: true
            )
        }
        guard observedDescriptor == descriptor else {
            throw OCIReferrerRegistryError.invalidResponse
        }
        guard try remover.verifyManifestIfPresent(
            root,
            descriptor: descriptor
        ) else {
            throw OCIReferrerRegistryError.invalidResponse
        }

        var fallbackRestoreETag: String?
        if discovery.mode != .native {
            guard let etag = discovery.etag else {
                throw OCIReferrerRegistryError.fallbackWriteUnavailable
            }
            fallbackRestoreETag = try remover.replaceFallbackIndex(
                descriptors: discovery.descriptors.filter {
                    $0.digest != referrerDigest
                },
                ifMatch: etag,
                requiredDigest: referrerDigest,
                requiredPresence: false
            )
        }

        do {
            try remover.deleteManifest(
                referrerDigest,
                expectedStatusMode: discovery.mode
            )
        } catch {
            if let fallbackRestoreETag {
                do {
                    _ = try remover.replaceFallbackIndex(
                        descriptors: discovery.descriptors,
                        ifMatch: fallbackRestoreETag,
                        requiredDigest: referrerDigest,
                        requiredPresence: true
                    )
                } catch {
                    throw OCIReferrerRegistryError.partialEffect
                }
            }
            throw error
        }

        let final = try discover(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: graph.discovery.subjectDigest,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation
        )
        guard !final.descriptors.contains(
            where: { $0.digest == referrerDigest }
        ) else {
            throw OCIReferrerRegistryError.partialEffect
        }
        return OCIReferrerRemovalResult(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: graph.discovery.subjectDigest,
            referrerDigest: referrerDigest,
            mode: discovery.mode == .native ? .native : .tagFallback,
            removed: true
        )
    }
}

private struct OCIReferrerRemover {
    let authenticationClient: RegistryAuthenticationClient
    let endpoint: RegistryEndpoint
    let repository: OCIRepositoryName
    let subjectDigest: OCIContentDigest
    let credential: RegistryCredential?
    let credentialKind: RegistryCredentialAuthorizationKind
    let cancellation: RegistryTransportCancellation
    let scope: RegistryAccessScopeSet

    init(
        authenticationClient: RegistryAuthenticationClient,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subjectDigest: OCIContentDigest,
        credential: RegistryCredential?,
        credentialKind: RegistryCredentialAuthorizationKind,
        cancellation: RegistryTransportCancellation
    ) throws {
        self.authenticationClient = authenticationClient
        self.endpoint = endpoint
        self.repository = repository
        self.subjectDigest = subjectDigest
        self.credential = credential
        self.credentialKind = credentialKind
        self.cancellation = cancellation
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

    func verifyManifestIfPresent(
        _ object: OCIReferrerFetchedObject,
        descriptor: OCIReferrerDescriptor
    ) throws -> Bool {
        let response = try send(
            RegistryTransportRequest(
                url: try manifestURL(object.digest.canonicalValue),
                method: .get,
                headers: ["Accept": object.mediaType]
            )
        )
        if response.statusCode == 404 {
            return false
        }
        guard response.statusCode == 200,
              response.body == object.payload,
              response.body.count == descriptor.size,
              try object.digest.matches(response.body),
              header("docker-content-digest", response) ==
                object.digest.canonicalValue else {
            throw OCIReferrerRegistryError.invalidResponse
        }
        let parsed: OCIParsedDocument
        do {
            parsed = try OCIParsedDocument.parse(response.body)
        } catch {
            throw OCIReferrerRegistryError.invalidResponse
        }
        guard parsed.subject?.digest == subjectDigest,
              parsed.effectiveArtifactType == descriptor.artifactType else {
            throw OCIReferrerRegistryError.subjectMismatch
        }
        return true
    }

    func replaceFallbackIndex(
        descriptors: [OCIReferrerDescriptor],
        ifMatch: String,
        requiredDigest: OCIContentDigest,
        requiredPresence: Bool
    ) throws -> String {
        guard !ifMatch.isEmpty, ifMatch.utf8.count <= 8_192 else {
            throw OCIReferrerRegistryError.fallbackWriteUnavailable
        }
        guard let fallbackTag = subjectDigest.exactReferrersTag else {
            throw OCIReferrerRegistryError.fallbackDigestUnsupported
        }
        let response = try send(
            RegistryTransportRequest(
                url: try manifestURL(fallbackTag),
                method: .put,
                headers: [
                    "Content-Type": OCIReferrerIndex.mediaType,
                    "If-Match": ifMatch
                ],
                body: try encodeIndex(descriptors)
            )
        )
        let observed = try observeFallbackIndex()
        let contains = observed.index.descriptors.contains {
            $0.digest == requiredDigest
        }
        guard contains == requiredPresence else {
            throw OCIReferrerRegistryError.partialEffect
        }
        guard response.statusCode == 201 ||
                response.statusCode == 202 else {
            throw OCIReferrerRegistryError.partialEffect
        }
        guard let etag = observed.etag,
              !etag.isEmpty,
              etag.utf8.count <= 8_192 else {
            throw OCIReferrerRegistryError.partialEffect
        }
        return etag
    }

    func deleteManifest(
        _ digest: OCIContentDigest,
        expectedStatusMode: OCIReferrerDiscoveryMode
    ) throws {
        let url = try manifestURL(digest.canonicalValue)
        let response: RegistryTransportResponse
        do {
            response = try send(
                RegistryTransportRequest(
                    url: url,
                    method: .delete
                )
            )
        } catch {
            let observation = try? send(
                RegistryTransportRequest(
                    url: url,
                    method: .get,
                    headers: [
                        "Accept":
                            OCIReferrerDescriptor.manifestMediaType
                    ]
                ),
                cancellation: RegistryTransportCancellation()
            )
            if observation?.statusCode == 404 {
                return
            }
            throw error
        }
        let observed = try send(
            RegistryTransportRequest(
                url: url,
                method: .get,
                headers: [
                    "Accept":
                        OCIReferrerDescriptor.manifestMediaType
                ]
            )
        )
        if observed.statusCode == 404 {
            return
        }
        guard observed.statusCode == 200 else {
            throw OCIReferrerRegistryError.partialEffect
        }
        guard [200, 202, 204].contains(response.statusCode) else {
            throw OCIReferrerRegistryError.unexpectedStatus(
                response.statusCode
            )
        }
        _ = expectedStatusMode
        throw OCIReferrerRegistryError.partialEffect
    }

    private func observeFallbackIndex() throws -> (
        index: OCIReferrerIndex,
        etag: String?
    ) {
        guard let fallbackTag = subjectDigest.exactReferrersTag else {
            throw OCIReferrerRegistryError.fallbackDigestUnsupported
        }
        let response = try send(
            RegistryTransportRequest(
                url: try manifestURL(fallbackTag),
                method: .get,
                headers: ["Accept": OCIReferrerIndex.mediaType]
            )
        )
        guard response.statusCode == 200,
              normalizedContentType(response) ==
                OCIReferrerIndex.mediaType else {
            throw OCIReferrerRegistryError.partialEffect
        }
        do {
            return (
                try OCIReferrerIndex.parse(
                    response.body,
                    subjectDigest: subjectDigest
                ),
                header("etag", response)
            )
        } catch {
            throw OCIReferrerRegistryError.partialEffect
        }
    }

    private func encodeIndex(
        _ descriptors: [OCIReferrerDescriptor]
    ) throws -> Data {
        let manifests: [[String: Any]] = descriptors.sorted {
            $0.digest.canonicalValue < $1.digest.canonicalValue
        }.map { descriptor in
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
        do {
            return try JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 2,
                    "mediaType": OCIReferrerIndex.mediaType,
                    "manifests": manifests
                ],
                options: [.sortedKeys]
            )
        } catch {
            throw OCIReferrerRegistryError.invalidRequest
        }
    }

    private func send(
        _ request: RegistryTransportRequest,
        cancellation selectedCancellation:
            RegistryTransportCancellation? = nil
    ) throws -> RegistryTransportResponse {
        do {
            return try authenticationClient.sendAuthorized(
                request,
                endpoint: endpoint,
                requestedScopes: scope,
                credential: credential,
                credentialKind: credentialKind,
                cancellation: selectedCancellation ?? cancellation
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

    private func manifestURL(_ reference: String) throws -> URL {
        guard let url = URL(
            string: endpoint.canonicalURLString +
                "/v2/\(repository.value)/manifests/\(reference)"
        ) else {
            throw OCIReferrerRegistryError.invalidRequest
        }
        return url
    }

    private func normalizedContentType(
        _ response: RegistryTransportResponse
    ) -> String? {
        header("content-type", response)?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func header(
        _ name: String,
        _ response: RegistryTransportResponse
    ) -> String? {
        response.headers.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

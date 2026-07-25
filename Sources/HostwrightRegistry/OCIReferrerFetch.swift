import Foundation

public extension OCIReferrerRegistryClient {
    func fetch(
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subjectDigest: OCIContentDigest,
        artifactType: OCIArtifactType? = nil,
        credential: RegistryCredential? = nil,
        credentialKind: RegistryCredentialAuthorizationKind = .basic,
        cancellation: RegistryTransportCancellation =
            RegistryTransportCancellation()
    ) throws -> OCIReferrerGraph {
        let discovery = try discover(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subjectDigest,
            artifactType: artifactType,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation
        )
        var fetcher = try OCIReferrerGraphFetcher(
            authenticationClient: authenticationClient,
            endpoint: endpoint,
            repository: repository,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation
        )
        var verified: [OCIReferrerDescriptor] = []
        for descriptor in discovery.descriptors {
            try fetcher.fetchRoot(
                descriptor,
                subjectDigest: subjectDigest
            )
            verified.append(descriptor)
        }
        do {
            return try OCIReferrerGraph(
                discovery: discovery,
                verifiedReferrers: verified,
                objects: fetcher.objects
            )
        } catch let error as OCIReferrerContractError
            where error == .limitExceeded {
            throw OCIReferrerRegistryError.limitExceeded
        } catch {
            throw OCIReferrerRegistryError.invalidGraph
        }
    }
}

private struct OCIReferrerGraphFetcher {
    let authenticationClient: RegistryAuthenticationClient
    let endpoint: RegistryEndpoint
    let repository: OCIRepositoryName
    let credential: RegistryCredential?
    let credentialKind: RegistryCredentialAuthorizationKind
    let cancellation: RegistryTransportCancellation
    let scope: RegistryAccessScopeSet

    private var objectsByDigest:
        [OCIContentDigest: OCIReferrerFetchedObject] = [:]
    private var declaredByDigest:
        [OCIContentDigest: OCIContentDescriptor] = [:]
    private var activeStack = Set<OCIContentDigest>()
    private var totalBytes = 0

    init(
        authenticationClient: RegistryAuthenticationClient,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        credential: RegistryCredential?,
        credentialKind: RegistryCredentialAuthorizationKind,
        cancellation: RegistryTransportCancellation
    ) throws {
        self.authenticationClient = authenticationClient
        self.endpoint = endpoint
        self.repository = repository
        self.credential = credential
        self.credentialKind = credentialKind
        self.cancellation = cancellation
        do {
            scope = try RegistryAccessScopeSet([
                RegistryAccessScope(
                    resourceType: .repository,
                    name: repository.value,
                    actions: [.pull]
                )
            ])
        } catch {
            throw OCIReferrerRegistryError.invalidRequest
        }
    }

    var objects: [OCIReferrerFetchedObject] {
        objectsByDigest.values.sorted {
            $0.digest.canonicalValue < $1.digest.canonicalValue
        }
    }

    mutating func fetchRoot(
        _ descriptor: OCIReferrerDescriptor,
        subjectDigest: OCIContentDigest
    ) throws {
        let contentDescriptor = try OCIContentDescriptor(
            mediaType: descriptor.mediaType,
            digest: descriptor.digest,
            size: descriptor.size,
            annotations: descriptor.annotations
        )
        try fetch(
            contentDescriptor,
            depth: 0,
            expectedSubject: subjectDigest,
            expectedArtifactType: descriptor.artifactType
        )
    }

    private mutating func fetch(
        _ descriptor: OCIContentDescriptor,
        depth: Int,
        expectedSubject: OCIContentDigest?,
        expectedArtifactType: OCIArtifactType?
    ) throws {
        guard depth <= OCIReferrerLimits.maximumGraphDepth else {
            throw OCIReferrerRegistryError.limitExceeded
        }
        if activeStack.contains(descriptor.digest) {
            throw OCIReferrerRegistryError.invalidGraph
        }
        if let existing = declaredByDigest[descriptor.digest] {
            guard existing.mediaType == descriptor.mediaType,
                  existing.size == descriptor.size else {
                throw OCIReferrerRegistryError.invalidGraph
            }
        } else {
            declaredByDigest[descriptor.digest] = descriptor
            guard declaredByDigest.count <=
                    OCIReferrerLimits.maximumGraphDescriptors else {
                throw OCIReferrerRegistryError.limitExceeded
            }
        }
        if objectsByDigest[descriptor.digest] != nil {
            return
        }
        guard !cancellation.isCancelled else {
            throw OCIReferrerRegistryError.cancelled
        }

        let kind = objectKind(for: descriptor.mediaType)
        let response = try send(
            RegistryTransportRequest(
                url: try objectURL(
                    digest: descriptor.digest,
                    kind: kind
                ),
                method: .get,
                headers: ["Accept": descriptor.mediaType],
                timeoutMilliseconds:
                    RegistryAuthenticationClient.timeoutMilliseconds
            )
        )
        guard response.statusCode == 200 else {
            throw OCIReferrerRegistryError.unexpectedStatus(
                response.statusCode
            )
        }
        guard response.body.count == descriptor.size,
              try descriptor.digest.matches(response.body) else {
            throw OCIReferrerRegistryError.digestMismatch
        }
        if let observedDigest = header(
            "docker-content-digest",
            response: response
        ) {
            guard observedDigest == descriptor.digest.canonicalValue else {
                throw OCIReferrerRegistryError.digestMismatch
            }
        }
        if let observedMediaType = header(
            "content-type",
            response: response
        )?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           observedMediaType != descriptor.mediaType {
            throw OCIReferrerRegistryError.invalidResponse
        }

        let children: [OCIContentDescriptor]
        if kind == .blob {
            children = []
        } else {
            let document: OCIParsedDocument
            do {
                document = try OCIParsedDocument.parse(response.body)
            } catch let error as OCIReferrerContractError
                where error == .limitExceeded {
                throw OCIReferrerRegistryError.limitExceeded
            } catch {
                throw OCIReferrerRegistryError.invalidResponse
            }
            guard document.mediaType == descriptor.mediaType,
                  document.kind == kind else {
                throw OCIReferrerRegistryError.invalidResponse
            }
            if let expectedSubject {
                guard document.subject?.digest == expectedSubject else {
                    throw OCIReferrerRegistryError.subjectMismatch
                }
                if let expectedArtifactType,
                   document.effectiveArtifactType != expectedArtifactType {
                    throw OCIReferrerRegistryError.invalidResponse
                }
            }
            children = document.children
        }

        let object: OCIReferrerFetchedObject
        do {
            object = try OCIReferrerFetchedObject(
                digest: descriptor.digest,
                mediaType: descriptor.mediaType,
                size: descriptor.size,
                kind: kind,
                payload: response.body,
                childDescriptors: children
            )
        } catch {
            throw OCIReferrerRegistryError.invalidResponse
        }
        totalBytes += object.size
        guard totalBytes <= OCIReferrerLimits.maximumGraphBytes else {
            throw OCIReferrerRegistryError.limitExceeded
        }
        objectsByDigest[descriptor.digest] = object

        activeStack.insert(descriptor.digest)
        defer { activeStack.remove(descriptor.digest) }
        for child in children {
            try fetch(
                child,
                depth: depth + 1,
                expectedSubject: nil,
                expectedArtifactType: nil
            )
        }
    }

    private func objectKind(
        for mediaType: String
    ) -> OCIReferrerObjectKind {
        switch mediaType {
        case OCIReferrerDescriptor.manifestMediaType:
            .manifest
        case OCIReferrerDescriptor.indexMediaType:
            .index
        default:
            .blob
        }
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

    private func send(
        _ request: RegistryTransportRequest
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

    private func header(
        _ name: String,
        response: RegistryTransportResponse
    ) -> String? {
        response.headers.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

import Foundation

public enum OCIReferrerDiscoveryMode:
    String,
    Codable,
    Equatable,
    Sendable
{
    case generated
    case native
    case tagFallback = "tag-fallback"
    case tagFallbackEmpty = "tag-fallback-empty"
}

public struct OCIReferrerDiscoveryResult: Equatable, Sendable {
    public let endpoint: RegistryEndpoint
    public let repository: OCIRepositoryName
    public let subjectDigest: OCIContentDigest
    public let artifactType: OCIArtifactType?
    public let mode: OCIReferrerDiscoveryMode
    public let serverFilterApplied: Bool
    public let pageCount: Int
    public let descriptors: [OCIReferrerDescriptor]
    public let etag: String?

    public init(
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subjectDigest: OCIContentDigest,
        artifactType: OCIArtifactType?,
        mode: OCIReferrerDiscoveryMode,
        serverFilterApplied: Bool,
        pageCount: Int,
        descriptors: [OCIReferrerDescriptor],
        etag: String?
    ) {
        self.endpoint = endpoint
        self.repository = repository
        self.subjectDigest = subjectDigest
        self.artifactType = artifactType
        self.mode = mode
        self.serverFilterApplied = serverFilterApplied
        self.pageCount = pageCount
        self.descriptors = descriptors
        self.etag = etag
    }
}

public enum OCIReferrerRegistryError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidRequest
    case authorizationFailed
    case invalidResponse
    case subjectMismatch
    case digestMismatch
    case invalidGraph
    case ownershipUnverified
    case fallbackDigestUnsupported
    case fallbackWriteUnavailable
    case unsafeUploadLocation
    case partialEffect
    case unexpectedStatus(Int)
    case paginationRejected
    case limitExceeded
    case transportUnavailable
    case cancelled

    public var description: String {
        switch self {
        case .invalidRequest:
            "OCI referrer registry request is invalid."
        case .authorizationFailed:
            "OCI referrer registry authorization failed."
        case .invalidResponse:
            "Registry returned malformed or inconsistent OCI referrer data."
        case .subjectMismatch:
            "OCI referrer manifest is not bound to the requested subject digest."
        case .digestMismatch:
            "OCI referrer content does not match its declared digest or size."
        case .invalidGraph:
            "OCI referrer graph is cyclic or internally inconsistent."
        case .ownershipUnverified:
            "OCI referrer mutation requires exact Hostwright ownership evidence."
        case .fallbackDigestUnsupported:
            "OCI referrer tag fallback cannot preserve exact identity for this digest algorithm."
        case .fallbackWriteUnavailable:
            "Registry fallback referrer updates lack a safe conflict validator."
        case .unsafeUploadLocation:
            "Registry returned an unsafe blob upload location."
        case .partialEffect:
            "OCI referrer mutation has an exact resumable partial effect."
        case .unexpectedStatus(let status):
            "Registry returned unexpected OCI referrer status \(status)."
        case .paginationRejected:
            "Registry returned an unsafe or inconsistent referrer pagination link."
        case .limitExceeded:
            "OCI referrer discovery exceeded a bounded Hostwright limit."
        case .transportUnavailable:
            "OCI referrer registry transport is unavailable."
        case .cancelled:
            "OCI referrer registry operation was cancelled."
        }
    }
}

public struct OCIReferrerRegistryClient: Sendable {
    let authenticationClient: RegistryAuthenticationClient

    public init(authenticationClient: RegistryAuthenticationClient) {
        self.authenticationClient = authenticationClient
    }

    public func discover(
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subjectDigest: OCIContentDigest,
        artifactType: OCIArtifactType? = nil,
        credential: RegistryCredential? = nil,
        credentialKind: RegistryCredentialAuthorizationKind = .basic,
        cancellation: RegistryTransportCancellation =
            RegistryTransportCancellation()
    ) throws -> OCIReferrerDiscoveryResult {
        let scope = try pullScope(repository)
        let initialURL = try referrersURL(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subjectDigest,
            artifactType: artifactType
        )
        let first = try send(
            request(url: initialURL, accept: OCIReferrerIndex.mediaType),
            endpoint: endpoint,
            scopes: scope,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation
        )
        if first.statusCode == 404 {
            return try discoverFallback(
                endpoint: endpoint,
                repository: repository,
                subjectDigest: subjectDigest,
                artifactType: artifactType,
                credential: credential,
                credentialKind: credentialKind,
                scope: scope,
                cancellation: cancellation
            )
        }
        guard first.statusCode == 200 else {
            throw OCIReferrerRegistryError.unexpectedStatus(
                first.statusCode
            )
        }

        var responses = [first]
        var visited = Set([initialURL.absoluteString])
        var currentURL = initialURL
        var totalBytes = first.body.count
        while let next = try nextURL(
            from: header("link", in: responses.last!),
            currentURL: currentURL,
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subjectDigest,
            artifactType: artifactType
        ) {
            guard responses.count < OCIReferrerLimits.maximumDiscoveryPages,
                  visited.insert(next.absoluteString).inserted else {
                throw OCIReferrerRegistryError.paginationRejected
            }
            let response = try send(
                request(url: next, accept: OCIReferrerIndex.mediaType),
                endpoint: endpoint,
                scopes: scope,
                credential: credential,
                credentialKind: credentialKind,
                cancellation: cancellation
            )
            guard response.statusCode == 200 else {
                throw OCIReferrerRegistryError.unexpectedStatus(
                    response.statusCode
                )
            }
            totalBytes += response.body.count
            guard totalBytes <= OCIReferrerLimits.maximumGraphBytes else {
                throw OCIReferrerRegistryError.limitExceeded
            }
            responses.append(response)
            currentURL = next
        }

        var byDigest: [OCIContentDigest: OCIReferrerDescriptor] = [:]
        var filterApplied = artifactType != nil
        for response in responses {
            try validateIndexContentType(response)
            let index: OCIReferrerIndex
            do {
                index = try OCIReferrerIndex.parse(
                    response.body,
                    subjectDigest: subjectDigest
                )
            } catch let error as OCIReferrerContractError {
                if error == .limitExceeded {
                    throw OCIReferrerRegistryError.limitExceeded
                }
                throw OCIReferrerRegistryError.invalidResponse
            } catch {
                throw OCIReferrerRegistryError.invalidResponse
            }
            if artifactType != nil {
                filterApplied = filterApplied &&
                    appliedArtifactFilter(response)
            }
            try merge(index.descriptors, into: &byDigest)
        }
        let descriptors = try filteredDescriptors(
            byDigest.values,
            artifactType: artifactType
        )
        return OCIReferrerDiscoveryResult(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subjectDigest,
            artifactType: artifactType,
            mode: .native,
            serverFilterApplied: filterApplied,
            pageCount: responses.count,
            descriptors: descriptors,
            etag: header("etag", in: first)
        )
    }

    private func discoverFallback(
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subjectDigest: OCIContentDigest,
        artifactType: OCIArtifactType?,
        credential: RegistryCredential?,
        credentialKind: RegistryCredentialAuthorizationKind,
        scope: RegistryAccessScopeSet,
        cancellation: RegistryTransportCancellation
    ) throws -> OCIReferrerDiscoveryResult {
        guard let fallbackTag = subjectDigest.exactReferrersTag else {
            throw OCIReferrerRegistryError.fallbackDigestUnsupported
        }
        let url = try manifestURL(
            endpoint: endpoint,
            repository: repository,
            reference: fallbackTag
        )
        let response = try send(
            request(url: url, accept: OCIReferrerIndex.mediaType),
            endpoint: endpoint,
            scopes: scope,
            credential: credential,
            credentialKind: credentialKind,
            cancellation: cancellation
        )
        if response.statusCode == 404 {
            return OCIReferrerDiscoveryResult(
                endpoint: endpoint,
                repository: repository,
                subjectDigest: subjectDigest,
                artifactType: artifactType,
                mode: .tagFallbackEmpty,
                serverFilterApplied: false,
                pageCount: 1,
                descriptors: [],
                etag: nil
            )
        }
        guard response.statusCode == 200 else {
            throw OCIReferrerRegistryError.unexpectedStatus(
                response.statusCode
            )
        }
        try validateIndexContentType(response)
        let index: OCIReferrerIndex
        do {
            index = try OCIReferrerIndex.parse(
                response.body,
                subjectDigest: subjectDigest
            )
        } catch {
            throw OCIReferrerRegistryError.invalidResponse
        }
        return OCIReferrerDiscoveryResult(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subjectDigest,
            artifactType: artifactType,
            mode: .tagFallback,
            serverFilterApplied: false,
            pageCount: 1,
            descriptors: try filteredDescriptors(
                index.descriptors,
                artifactType: artifactType
            ),
            etag: header("etag", in: response)
        )
    }

    private func send(
        _ request: RegistryTransportRequest,
        endpoint: RegistryEndpoint,
        scopes: RegistryAccessScopeSet,
        credential: RegistryCredential?,
        credentialKind: RegistryCredentialAuthorizationKind,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        do {
            return try authenticationClient.sendAuthorized(
                request,
                endpoint: endpoint,
                requestedScopes: scopes,
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

    private func merge(
        _ descriptors: [OCIReferrerDescriptor],
        into values: inout [OCIContentDigest: OCIReferrerDescriptor]
    ) throws {
        for descriptor in descriptors {
            if let existing = values[descriptor.digest],
               existing != descriptor {
                throw OCIReferrerRegistryError.invalidResponse
            }
            values[descriptor.digest] = descriptor
        }
        guard values.count <=
                OCIReferrerLimits.maximumReferrerDescriptors else {
            throw OCIReferrerRegistryError.limitExceeded
        }
    }

    private func filteredDescriptors(
        _ descriptors: some Sequence<OCIReferrerDescriptor>,
        artifactType: OCIArtifactType?
    ) throws -> [OCIReferrerDescriptor] {
        let values = descriptors.filter { descriptor in
            guard let artifactType else { return true }
            return descriptor.artifactType == artifactType
        }.sorted {
            $0.digest.canonicalValue < $1.digest.canonicalValue
        }
        guard values.count <=
                OCIReferrerLimits.maximumReferrerDescriptors else {
            throw OCIReferrerRegistryError.limitExceeded
        }
        return values
    }

    private func pullScope(
        _ repository: OCIRepositoryName
    ) throws -> RegistryAccessScopeSet {
        do {
            return try RegistryAccessScopeSet([
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

    private func referrersURL(
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subjectDigest: OCIContentDigest,
        artifactType: OCIArtifactType?
    ) throws -> URL {
        guard var components = URLComponents(
            string: endpoint.canonicalURLString +
                "/v2/\(repository.value)/referrers/" +
                subjectDigest.canonicalValue
        ) else {
            throw OCIReferrerRegistryError.invalidRequest
        }
        if let artifactType {
            components.queryItems = [
                URLQueryItem(
                    name: "artifactType",
                    value: artifactType.value
                )
            ]
        }
        guard let url = components.url else {
            throw OCIReferrerRegistryError.invalidRequest
        }
        return url
    }

    private func manifestURL(
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        reference: String
    ) throws -> URL {
        guard let url = URL(
            string: endpoint.canonicalURLString +
                "/v2/\(repository.value)/manifests/\(reference)"
        ) else {
            throw OCIReferrerRegistryError.invalidRequest
        }
        return url
    }

    private func request(
        url: URL,
        accept: String
    ) -> RegistryTransportRequest {
        RegistryTransportRequest(
            url: url,
            method: .get,
            headers: ["Accept": accept],
            timeoutMilliseconds:
                RegistryAuthenticationClient.timeoutMilliseconds
        )
    }

    private func validateIndexContentType(
        _ response: RegistryTransportResponse
    ) throws {
        let value = header("content-type", in: response)?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == OCIReferrerIndex.mediaType else {
            throw OCIReferrerRegistryError.invalidResponse
        }
    }

    private func appliedArtifactFilter(
        _ response: RegistryTransportResponse
    ) -> Bool {
        header("oci-filters-applied", in: response)?
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
            .contains("artifacttype") == true
    }

    private func header(
        _ name: String,
        in response: RegistryTransportResponse
    ) -> String? {
        response.headers.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    private func nextURL(
        from linkHeader: String?,
        currentURL: URL,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subjectDigest: OCIContentDigest,
        artifactType: OCIArtifactType?
    ) throws -> URL? {
        guard let linkHeader else { return nil }
        guard linkHeader.utf8.count <= 8_192 else {
            throw OCIReferrerRegistryError.paginationRejected
        }
        var candidates: [URL] = []
        for rawSegment in linkHeader.split(separator: ",") {
            let segment = rawSegment.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard segment.hasPrefix("<"),
                  let closing = segment.firstIndex(of: ">") else {
                throw OCIReferrerRegistryError.paginationRejected
            }
            let target = String(
                segment[
                    segment.index(after: segment.startIndex)..<closing
                ]
            )
            let parameters = segment[
                segment.index(after: closing)...
            ].split(separator: ";")
            let isNext = parameters.contains { parameter in
                let value = parameter.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return value.caseInsensitiveCompare(
                    #"rel="next""#
                ) == .orderedSame || value.caseInsensitiveCompare(
                    "rel=next"
                ) == .orderedSame
            }
            if isNext {
                guard let resolved = URL(
                    string: target,
                    relativeTo: currentURL
                )?.absoluteURL else {
                    throw OCIReferrerRegistryError.paginationRejected
                }
                candidates.append(resolved)
            }
        }
        guard candidates.count <= 1 else {
            throw OCIReferrerRegistryError.paginationRejected
        }
        guard let candidate = candidates.first else { return nil }
        try validatePaginationURL(
            candidate,
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subjectDigest,
            artifactType: artifactType
        )
        return candidate
    }

    private func validatePaginationURL(
        _ url: URL,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        subjectDigest: OCIContentDigest,
        artifactType: OCIArtifactType?
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == endpoint.url.host?.lowercased(),
              (url.port ?? 443) == (endpoint.url.port ?? 443),
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.path ==
                "/v2/\(repository.value)/referrers/" +
                subjectDigest.canonicalValue,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              (components.queryItems ?? []).count <= 16 else {
            throw OCIReferrerRegistryError.paginationRejected
        }
        let filters = (components.queryItems ?? []).filter {
            $0.name == "artifactType"
        }
        if let artifactType {
            guard filters.count == 1,
                  filters[0].value == artifactType.value else {
                throw OCIReferrerRegistryError.paginationRejected
            }
        } else if !filters.isEmpty {
            throw OCIReferrerRegistryError.paginationRejected
        }
        guard (components.queryItems ?? []).allSatisfy({
            !$0.name.isEmpty &&
                $0.name.utf8.count <= 256 &&
                ($0.value?.utf8.count ?? 0) <= 2_048 &&
                !$0.name.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0)
                } &&
                !($0.value?.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0)
                } ?? false)
        }) else {
            throw OCIReferrerRegistryError.paginationRejected
        }
    }
}

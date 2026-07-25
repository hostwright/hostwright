import CryptoKit
import Foundation

public enum RegistryCredentialAuthorizationKind: String, Equatable, Sendable {
    case basic
    case identityToken = "identity-token"
}

public enum RegistryAuthenticationError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidRequest
    case credentialUnavailable
    case authenticationDenied
    case scopeDenied
    case invalidResponse
    case transportUnavailable
    case cancelled

    public var description: String {
        switch self {
        case .invalidRequest:
            "The registry authentication request is invalid."
        case .credentialUnavailable:
            "The registry requires a credential, but no exact credential is available."
        case .authenticationDenied:
            "The registry rejected the supplied credential."
        case .scopeDenied:
            "The registry rejected or attempted to expand the requested access scope."
        case .invalidResponse:
            "The registry returned an invalid authentication response."
        case .transportUnavailable:
            "The registry authentication transport is unavailable."
        case .cancelled:
            "Registry authentication was cancelled."
        }
    }
}

public enum RegistryAuthenticationResultKind: String, Equatable, Sendable {
    case anonymous
    case basic
    case bearer
}

public struct RegistryAuthenticationResult: Equatable, Sendable {
    public let endpoint: RegistryEndpoint
    public let kind: RegistryAuthenticationResultKind
    public let requestedScopes: RegistryAccessScopeSet
    public let grantedScopes: RegistryAccessScopeSet
    public let tokenExpiresAt: Date?
    public let tokenRefreshAvailable: Bool
    public let distributionAPIVersionVerified: Bool

    public init(
        endpoint: RegistryEndpoint,
        kind: RegistryAuthenticationResultKind,
        requestedScopes: RegistryAccessScopeSet,
        grantedScopes: RegistryAccessScopeSet,
        tokenExpiresAt: Date?,
        tokenRefreshAvailable: Bool,
        distributionAPIVersionVerified: Bool
    ) {
        self.endpoint = endpoint
        self.kind = kind
        self.requestedScopes = requestedScopes
        self.grantedScopes = grantedScopes
        self.tokenExpiresAt = tokenExpiresAt
        self.tokenRefreshAvailable = tokenRefreshAvailable
        self.distributionAPIVersionVerified = distributionAPIVersionVerified
    }
}

public struct RegistryAuthorizedResponse:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let response: RegistryTransportResponse
    public let authentication: RegistryAuthenticationResult

    public init(
        response: RegistryTransportResponse,
        authentication: RegistryAuthenticationResult
    ) {
        self.response = response
        self.authentication = authentication
    }

    public var description: String {
        "Registry authorized response (status: \(response.statusCode), authentication: \(authentication.kind.rawValue), body: redacted)."
    }

    public var debugDescription: String {
        description
    }
}

public final class RegistryAuthenticationClient: @unchecked Sendable {
    public static let timeoutMilliseconds = 30_000
    public static let maximumCachedEntries = 64

    private let transport: any RegistrySynchronousHTTPTransporting
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [CacheKey: CacheEntry] = [:]

    public init(
        transport: any RegistrySynchronousHTTPTransporting =
            SynchronousURLSessionRegistryTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    public func authenticate(
        endpoint: RegistryEndpoint,
        requestedScopes: RegistryAccessScopeSet = .empty,
        credential: RegistryCredential? = nil,
        credentialKind: RegistryCredentialAuthorizationKind = .basic,
        cancellation: RegistryTransportCancellation =
            RegistryTransportCancellation()
    ) throws -> RegistryAuthenticationResult {
        try requireNotCancelled(cancellation)
        let key = CacheKey(
            endpoint: endpoint.canonicalURLString,
            scopes: requestedScopes.canonicalValue
        )
        let fingerprint = credentialFingerprint(credential, kind: credentialKind)

        if credentialKind == .identityToken, let credential {
            let result = try directIdentityToken(
                endpoint: endpoint,
                requestedScopes: requestedScopes,
                credential: credential,
                cancellation: cancellation
            )
            if result != nil {
                return result!
            }
        }

        if let cached = cachedEntry(key, matching: fingerprint) {
            if cached.token.needsRefresh(at: now()) {
                if let refreshed = try? refresh(
                    cached,
                    requestedScopes: requestedScopes,
                    cancellation: cancellation
                ) {
                    setCachedEntry(refreshed, for: key)
                    if let result = try useBearer(
                        refreshed,
                        endpoint: endpoint,
                        requestedScopes: requestedScopes,
                        cancellation: cancellation
                    ) {
                        return result
                    }
                }
                removeCachedEntry(for: key)
            } else if let result = try useBearer(
                cached,
                endpoint: endpoint,
                requestedScopes: requestedScopes,
                cancellation: cancellation
            ) {
                return result
            } else {
                removeCachedEntry(for: key)
            }
        }

        let initial = try sendRegistry(
            endpoint: endpoint,
            authorization: nil,
            cancellation: cancellation
        )
        if Self.isSuccess(initial.statusCode) {
            return RegistryAuthenticationResult(
                endpoint: endpoint,
                kind: .anonymous,
                requestedScopes: requestedScopes,
                grantedScopes: .empty,
                tokenExpiresAt: nil,
                tokenRefreshAvailable: false,
                distributionAPIVersionVerified:
                    Self.hasDistributionAPIVersion(initial)
            )
        }
        guard initial.statusCode == 401 else {
            throw responseError(initial)
        }
        guard let header = initial.headers["www-authenticate"] else {
            throw RegistryAuthenticationError.invalidResponse
        }

        let challenge: RegistryAuthenticationChallenge
        do {
            challenge = try RegistryAuthenticationChallenge.parse(header)
        } catch {
            throw RegistryAuthenticationError.invalidResponse
        }

        switch challenge {
        case .basic:
            guard let credential else {
                throw RegistryAuthenticationError.credentialUnavailable
            }
            let authorization = try basicAuthorization(credential)
            let response = try sendRegistry(
                endpoint: endpoint,
                authorization: authorization,
                cancellation: cancellation
            )
            guard Self.isSuccess(response.statusCode) else {
                throw responseError(response)
            }
            return RegistryAuthenticationResult(
                endpoint: endpoint,
                kind: .basic,
                requestedScopes: requestedScopes,
                grantedScopes: .empty,
                tokenExpiresAt: nil,
                tokenRefreshAvailable: false,
                distributionAPIVersionVerified:
                    Self.hasDistributionAPIVersion(response)
            )
        case .bearer(let bearer):
            guard bearer.scopes.scopes.isEmpty ||
                    bearer.scopes.isSubset(of: requestedScopes) else {
                throw RegistryAuthenticationError.scopeDenied
            }
            let token = try acquireToken(
                challenge: bearer,
                requestedScopes: requestedScopes,
                credential: credential,
                cancellation: cancellation
            )
            let entry = CacheEntry(
                token: token,
                realm: bearer.realm,
                service: bearer.service,
                credentialFingerprint: fingerprint
            )
            setCachedEntry(entry, for: key)
            guard let result = try useBearer(
                entry,
                endpoint: endpoint,
                requestedScopes: requestedScopes,
                cancellation: cancellation
            ) else {
                removeCachedEntry(for: key)
                throw RegistryAuthenticationError.authenticationDenied
            }
            return result
        }
    }

    public func invalidate(endpoint: RegistryEndpoint) {
        lock.withLock {
            cache = cache.filter { $0.key.endpoint != endpoint.canonicalURLString }
        }
    }

    public func sendAuthorized(
        _ request: RegistryTransportRequest,
        endpoint: RegistryEndpoint,
        requestedScopes: RegistryAccessScopeSet,
        credential: RegistryCredential? = nil,
        credentialKind: RegistryCredentialAuthorizationKind = .basic,
        cancellation: RegistryTransportCancellation =
            RegistryTransportCancellation()
    ) throws -> RegistryAuthorizedResponse {
        try requireNotCancelled(cancellation)
        try validateAuthorizedRequest(request, endpoint: endpoint)

        let key = CacheKey(
            endpoint: endpoint.canonicalURLString,
            scopes: requestedScopes.canonicalValue
        )
        let fingerprint = credentialFingerprint(
            credential,
            kind: credentialKind
        )

        if credentialKind == .identityToken, let credential {
            let authorization = try credential.withSecret {
                try RegistryTransportAuthorization(
                    scheme: .bearer,
                    value: $0
                )
            }
            let response = try send(
                request.withAuthorization(authorization),
                cancellation: cancellation
            )
            if response.statusCode != 401 {
                return authorizedResponse(
                    response,
                    endpoint: endpoint,
                    requestedScopes: requestedScopes,
                    kind: .bearer
                )
            }
        }

        if var cached = cachedEntry(key, matching: fingerprint) {
            if cached.token.needsRefresh(at: now()) {
                do {
                    cached = try refresh(
                        cached,
                        requestedScopes: requestedScopes,
                        cancellation: cancellation
                    )
                    setCachedEntry(cached, for: key)
                } catch RegistryAuthenticationError.cancelled {
                    throw RegistryAuthenticationError.cancelled
                } catch {
                    removeCachedEntry(for: key)
                }
            }
            if let current = cachedEntry(key, matching: fingerprint),
               let result = try useBearer(
                   current,
                   request: request,
                   endpoint: endpoint,
                   requestedScopes: requestedScopes,
                   cancellation: cancellation
               ) {
                return result
            }
            removeCachedEntry(for: key)
        }

        let initial = try send(request, cancellation: cancellation)
        if initial.statusCode != 401 {
            return authorizedResponse(
                initial,
                endpoint: endpoint,
                requestedScopes: requestedScopes,
                kind: .anonymous
            )
        }
        guard let header = initial.headers["www-authenticate"] else {
            throw RegistryAuthenticationError.invalidResponse
        }

        let challenge: RegistryAuthenticationChallenge
        do {
            challenge = try RegistryAuthenticationChallenge.parse(header)
        } catch {
            throw RegistryAuthenticationError.invalidResponse
        }
        switch challenge {
        case .basic:
            guard let credential else {
                throw RegistryAuthenticationError.credentialUnavailable
            }
            let response = try send(
                request.withAuthorization(
                    try basicAuthorization(credential)
                ),
                cancellation: cancellation
            )
            guard response.statusCode != 401 else {
                throw RegistryAuthenticationError.authenticationDenied
            }
            return authorizedResponse(
                response,
                endpoint: endpoint,
                requestedScopes: requestedScopes,
                kind: .basic
            )
        case .bearer(let bearer):
            guard bearer.scopes.scopes.isEmpty ||
                    bearer.scopes.isSubset(of: requestedScopes) else {
                throw RegistryAuthenticationError.scopeDenied
            }
            let token = try acquireToken(
                challenge: bearer,
                requestedScopes: requestedScopes,
                credential: credential,
                cancellation: cancellation
            )
            let entry = CacheEntry(
                token: token,
                realm: bearer.realm,
                service: bearer.service,
                credentialFingerprint: fingerprint
            )
            setCachedEntry(entry, for: key)
            guard let result = try useBearer(
                entry,
                request: request,
                endpoint: endpoint,
                requestedScopes: requestedScopes,
                cancellation: cancellation
            ) else {
                removeCachedEntry(for: key)
                throw RegistryAuthenticationError.authenticationDenied
            }
            return result
        }
    }

    private func directIdentityToken(
        endpoint: RegistryEndpoint,
        requestedScopes: RegistryAccessScopeSet,
        credential: RegistryCredential,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryAuthenticationResult? {
        let authorization = try credential.withSecret {
            try RegistryTransportAuthorization(scheme: .bearer, value: $0)
        }
        let response = try sendRegistry(
            endpoint: endpoint,
            authorization: authorization,
            cancellation: cancellation
        )
        if response.statusCode == 401 {
            return nil
        }
        guard Self.isSuccess(response.statusCode) else {
            throw responseError(response)
        }
        return RegistryAuthenticationResult(
            endpoint: endpoint,
            kind: .bearer,
            requestedScopes: requestedScopes,
            grantedScopes: .empty,
            tokenExpiresAt: nil,
            tokenRefreshAvailable: false,
            distributionAPIVersionVerified: Self.hasDistributionAPIVersion(response)
        )
    }

    private func useBearer(
        _ entry: CacheEntry,
        endpoint: RegistryEndpoint,
        requestedScopes: RegistryAccessScopeSet,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryAuthenticationResult? {
        let authorization = try entry.token.withAccessToken {
            try RegistryTransportAuthorization(scheme: .bearer, value: $0)
        }
        let response = try sendRegistry(
            endpoint: endpoint,
            authorization: authorization,
            cancellation: cancellation
        )
        if response.statusCode == 401 {
            return nil
        }
        guard Self.isSuccess(response.statusCode) else {
            throw responseError(response)
        }
        let granted = entry.token.grantedScopes ?? requestedScopes
        guard requestedScopes.isSubset(of: granted) else {
            throw RegistryAuthenticationError.scopeDenied
        }
        var refreshAvailable = false
        entry.token.withRefreshToken { refreshAvailable = $0 != nil }
        return RegistryAuthenticationResult(
            endpoint: endpoint,
            kind: .bearer,
            requestedScopes: requestedScopes,
            grantedScopes: granted,
            tokenExpiresAt: entry.token.expiresAt,
            tokenRefreshAvailable: refreshAvailable,
            distributionAPIVersionVerified: Self.hasDistributionAPIVersion(response)
        )
    }

    private func useBearer(
        _ entry: CacheEntry,
        request: RegistryTransportRequest,
        endpoint: RegistryEndpoint,
        requestedScopes: RegistryAccessScopeSet,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryAuthorizedResponse? {
        let granted = entry.token.grantedScopes ?? requestedScopes
        guard requestedScopes.isSubset(of: granted) else {
            throw RegistryAuthenticationError.scopeDenied
        }
        let authorization = try entry.token.withAccessToken {
            try RegistryTransportAuthorization(scheme: .bearer, value: $0)
        }
        let response = try send(
            request.withAuthorization(authorization),
            cancellation: cancellation
        )
        if response.statusCode == 401 {
            return nil
        }
        var refreshAvailable = false
        entry.token.withRefreshToken { refreshAvailable = $0 != nil }
        return RegistryAuthorizedResponse(
            response: response,
            authentication: RegistryAuthenticationResult(
                endpoint: endpoint,
                kind: .bearer,
                requestedScopes: requestedScopes,
                grantedScopes: granted,
                tokenExpiresAt: entry.token.expiresAt,
                tokenRefreshAvailable: refreshAvailable,
                distributionAPIVersionVerified:
                    Self.hasDistributionAPIVersion(response)
            )
        )
    }

    private func acquireToken(
        challenge: RegistryBearerChallenge,
        requestedScopes: RegistryAccessScopeSet,
        credential: RegistryCredential?,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTokenResponse {
        let components = URLComponents(
            url: challenge.realm,
            resolvingAgainstBaseURL: false
        )
        guard var components else {
            throw RegistryAuthenticationError.invalidResponse
        }
        let reserved = Set(["client_id", "offline_token", "scope", "service"])
        guard !(components.queryItems ?? []).contains(where: {
            reserved.contains($0.name.lowercased())
        }) else {
            throw RegistryAuthenticationError.invalidResponse
        }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "client_id", value: "hostwright"))
        if credential != nil {
            query.append(URLQueryItem(name: "offline_token", value: "true"))
        }
        if let service = challenge.service {
            query.append(URLQueryItem(name: "service", value: service))
        }
        if !requestedScopes.scopes.isEmpty {
            query.append(
                URLQueryItem(
                    name: "scope",
                    value: requestedScopes.canonicalValue
                )
            )
        }
        components.queryItems = query
        guard let url = components.url else {
            throw RegistryAuthenticationError.invalidResponse
        }
        let authorization = try credential.map(basicAuthorization)
        let response = try send(
            RegistryTransportRequest(
                url: url,
                method: .get,
                headers: ["Accept": "application/json"],
                authorization: authorization,
                timeoutMilliseconds: Self.timeoutMilliseconds
            ),
            cancellation: cancellation
        )
        guard Self.isSuccess(response.statusCode) else {
            throw responseError(response)
        }
        do {
            return try RegistryTokenResponse.parse(
                response.body,
                receivedAt: now(),
                requestedScopes: requestedScopes
            )
        } catch {
            throw RegistryAuthenticationError.invalidResponse
        }
    }

    private func refresh(
        _ entry: CacheEntry,
        requestedScopes: RegistryAccessScopeSet,
        cancellation: RegistryTransportCancellation
    ) throws -> CacheEntry {
        let body: Data = try entry.token.withRefreshToken { refreshToken in
            guard let refreshToken else {
                throw RegistryAuthenticationError.credentialUnavailable
            }
            var fields = [
                URLQueryItem(name: "client_id", value: "hostwright"),
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken)
            ]
            if let service = entry.service {
                fields.append(URLQueryItem(name: "service", value: service))
            }
            if !requestedScopes.scopes.isEmpty {
                fields.append(
                    URLQueryItem(
                        name: "scope",
                        value: requestedScopes.canonicalValue
                    )
                )
            }
            var form = URLComponents()
            form.queryItems = fields
            guard let encoded = form.percentEncodedQuery?.data(using: .utf8) else {
                throw RegistryAuthenticationError.invalidRequest
            }
            return encoded
        }
        let response = try send(
            RegistryTransportRequest(
                url: entry.realm,
                method: .post,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded"
                ],
                body: body,
                timeoutMilliseconds: Self.timeoutMilliseconds
            ),
            cancellation: cancellation
        )
        guard Self.isSuccess(response.statusCode) else {
            throw responseError(response)
        }
        let token: RegistryTokenResponse
        do {
            token = try RegistryTokenResponse.parse(
                response.body,
                receivedAt: now(),
                requestedScopes: requestedScopes
            )
        } catch {
            throw RegistryAuthenticationError.invalidResponse
        }
        return CacheEntry(
            token: token,
            realm: entry.realm,
            service: entry.service,
            credentialFingerprint: entry.credentialFingerprint
        )
    }

    private func sendRegistry(
        endpoint: RegistryEndpoint,
        authorization: RegistryTransportAuthorization?,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        let url = endpoint.url.appendingPathComponent("v2", isDirectory: true)
        return try send(
            RegistryTransportRequest(
                url: url,
                method: .get,
                headers: [
                    "Accept": "application/json",
                    "Docker-Distribution-API-Version": "registry/2.0"
                ],
                authorization: authorization,
                timeoutMilliseconds: Self.timeoutMilliseconds
            ),
            cancellation: cancellation
        )
    }

    private func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        try requireNotCancelled(cancellation)
        do {
            let response = try transport.send(
                request,
                cancellation: cancellation
            )
            try requireNotCancelled(cancellation)
            return response
        } catch let error as RegistryTransportError {
            switch error {
            case .cancelled:
                throw RegistryAuthenticationError.cancelled
            case .redirectRejected:
                throw RegistryAuthenticationError.invalidResponse
            case .invalidURL, .insecureTransport, .invalidMethod,
                 .invalidHeader, .invalidAuthorization, .requestBodyTooLarge,
                 .responseBodyTooLarge, .responseHeadersTooLarge,
                 .invalidTimeout, .invalidResponse:
                throw RegistryAuthenticationError.invalidResponse
            case .timedOut, .transportFailed:
                throw RegistryAuthenticationError.transportUnavailable
            }
        } catch let error as RegistryAuthenticationError {
            throw error
        } catch {
            throw RegistryAuthenticationError.transportUnavailable
        }
    }

    private func basicAuthorization(
        _ credential: RegistryCredential
    ) throws -> RegistryTransportAuthorization {
        try credential.withSecret { secret in
            let value = Data("\(credential.username):\(secret)".utf8)
                .base64EncodedString()
            return try RegistryTransportAuthorization(
                scheme: .basic,
                value: value
            )
        }
    }

    private func responseError(
        _ response: RegistryTransportResponse
    ) -> RegistryAuthenticationError {
        switch response.statusCode {
        case 401, 403:
            .authenticationDenied
        case 429, 500...599:
            .transportUnavailable
        default:
            .invalidResponse
        }
    }

    private func requireNotCancelled(
        _ cancellation: RegistryTransportCancellation
    ) throws {
        guard !cancellation.isCancelled else {
            throw RegistryAuthenticationError.cancelled
        }
    }

    private func validateAuthorizedRequest(
        _ request: RegistryTransportRequest,
        endpoint: RegistryEndpoint
    ) throws {
        guard request.authorization == nil,
              request.url.scheme?.lowercased() == "https",
              request.url.user == nil,
              request.url.password == nil,
              request.url.fragment == nil,
              request.url.host?.lowercased() ==
                endpoint.url.host?.lowercased(),
              (request.url.port ?? 443) == (endpoint.url.port ?? 443) else {
            throw RegistryAuthenticationError.invalidRequest
        }
        guard let encodedPath = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath else {
            throw RegistryAuthenticationError.invalidRequest
        }
        let path = encodedPath
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard path.hasPrefix("/v2/"),
              !path.contains("\\"),
              !path.lowercased().contains("%2f"),
              !path.lowercased().contains("%5c"),
              !components.contains("."),
              !components.contains("..") else {
            throw RegistryAuthenticationError.invalidRequest
        }
    }

    private func authorizedResponse(
        _ response: RegistryTransportResponse,
        endpoint: RegistryEndpoint,
        requestedScopes: RegistryAccessScopeSet,
        kind: RegistryAuthenticationResultKind
    ) -> RegistryAuthorizedResponse {
        RegistryAuthorizedResponse(
            response: response,
            authentication: RegistryAuthenticationResult(
                endpoint: endpoint,
                kind: kind,
                requestedScopes: requestedScopes,
                grantedScopes: .empty,
                tokenExpiresAt: nil,
                tokenRefreshAvailable: false,
                distributionAPIVersionVerified:
                    Self.hasDistributionAPIVersion(response)
            )
        )
    }

    private func credentialFingerprint(
        _ credential: RegistryCredential?,
        kind: RegistryCredentialAuthorizationKind
    ) -> String {
        guard let credential else {
            return "none"
        }
        return credential.withSecret { secret in
            var data = Data(kind.rawValue.utf8)
            data.append(0)
            data.append(Data(credential.username.utf8))
            data.append(0)
            data.append(Data(secret.utf8))
            return SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    private func cachedEntry(
        _ key: CacheKey,
        matching fingerprint: String
    ) -> CacheEntry? {
        lock.withLock {
            guard let entry = cache[key],
                  entry.credentialFingerprint == fingerprint else {
                cache.removeValue(forKey: key)
                return nil
            }
            return entry
        }
    }

    private func setCachedEntry(_ entry: CacheEntry, for key: CacheKey) {
        lock.withLock {
            if cache[key] == nil, cache.count >= Self.maximumCachedEntries {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = entry
        }
    }

    private func removeCachedEntry(for key: CacheKey) {
        lock.withLock { _ = cache.removeValue(forKey: key) }
    }

    private static func isSuccess(_ statusCode: Int) -> Bool {
        (200...299).contains(statusCode)
    }

    private static func hasDistributionAPIVersion(
        _ response: RegistryTransportResponse
    ) -> Bool {
        response.headers["docker-distribution-api-version"]?
            .lowercased()
            .contains("registry/2.0") == true
    }

    private struct CacheKey: Hashable {
        let endpoint: String
        let scopes: String
    }

    private struct CacheEntry {
        let token: RegistryTokenResponse
        let realm: URL
        let service: String?
        let credentialFingerprint: String
    }
}

private extension RegistryTransportRequest {
    func withAuthorization(
        _ authorization: RegistryTransportAuthorization
    ) -> RegistryTransportRequest {
        RegistryTransportRequest(
            url: url,
            method: method,
            headers: headers,
            authorization: authorization,
            body: body,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }
}

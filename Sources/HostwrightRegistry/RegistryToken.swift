import Foundation

public struct RegistryTokenResponse:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public static let maximumResponseBytes = 64 * 1_024
    public static let defaultLifetime: TimeInterval = 60
    public static let maximumLifetime: TimeInterval = 31_536_000
    public static let maximumFutureIssuedAtSkew: TimeInterval = 300

    private let accessToken: RegistrySecret
    private let refreshToken: RegistrySecret?

    public let issuedAt: Date
    public let expiresAt: Date
    public let grantedScopes: RegistryAccessScopeSet?

    public static func parse(
        _ data: Data,
        receivedAt: Date,
        requestedScopes: RegistryAccessScopeSet? = nil
    ) throws -> RegistryTokenResponse {
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes: maximumResponseBytes
            )
        } catch {
            throw RegistryContractError.invalidTokenResponse(
                "Registry token response must be one bounded JSON object without duplicate fields."
            )
        }

        let tokenValue = object["token"] as? String
        let accessTokenValue = object["access_token"] as? String
        if object["token"] != nil, tokenValue == nil {
            throw RegistryContractError.invalidTokenResponse(
                "Registry token response token must be a string."
            )
        }
        if object["access_token"] != nil, accessTokenValue == nil {
            throw RegistryContractError.invalidTokenResponse(
                "Registry token response access_token must be a string."
            )
        }
        guard let resolvedToken = tokenValue ?? accessTokenValue else {
            throw RegistryContractError.invalidTokenResponse(
                "Registry token response must contain token or access_token."
            )
        }
        if let tokenValue, let accessTokenValue, tokenValue != accessTokenValue {
            throw RegistryContractError.invalidTokenResponse(
                "Registry token response contains conflicting token values."
            )
        }

        let lifetime: TimeInterval
        if object["expires_in"] == nil {
            lifetime = defaultLifetime
        } else {
            guard let seconds = RegistryStrictJSONObject.integer(object["expires_in"]),
                  seconds >= 0,
                  TimeInterval(seconds) <= maximumLifetime else {
                throw RegistryContractError.invalidTokenResponse(
                    "Registry token response expires_in must be a bounded non-negative integer."
                )
            }
            lifetime = TimeInterval(seconds)
        }

        let issuedAt: Date
        if let rawIssuedAt = object["issued_at"] {
            guard let timestamp = rawIssuedAt as? String,
                  timestamp.utf8.count <= 128,
                  let parsed = Self.parseTimestamp(timestamp),
                  parsed <= receivedAt.addingTimeInterval(maximumFutureIssuedAtSkew) else {
                throw RegistryContractError.invalidTokenResponse(
                    "Registry token response issued_at must be a valid non-future RFC3339 timestamp."
                )
            }
            issuedAt = parsed
        } else {
            issuedAt = receivedAt
        }

        let refreshToken: RegistrySecret?
        if let rawRefreshToken = object["refresh_token"] {
            guard let value = rawRefreshToken as? String else {
                throw RegistryContractError.invalidTokenResponse(
                    "Registry token response refresh_token must be a string."
                )
            }
            refreshToken = try Self.tokenSecret(value)
        } else {
            refreshToken = nil
        }

        let grantedScopes: RegistryAccessScopeSet?
        if let rawScope = object["scope"] {
            guard let value = rawScope as? String else {
                throw RegistryContractError.invalidTokenResponse(
                    "Registry token response scope must be a string."
                )
            }
            let parsed: RegistryAccessScopeSet
            do {
                parsed = try RegistryAccessScopeSet.parse(value)
            } catch {
                throw RegistryContractError.invalidTokenResponse(
                    "Registry token response scope is malformed."
                )
            }
            if let requestedScopes, !parsed.isSubset(of: requestedScopes) {
                throw RegistryContractError.invalidTokenResponse(
                    "Registry token response attempted to escalate the requested scope."
                )
            }
            grantedScopes = parsed
        } else {
            grantedScopes = nil
        }

        return RegistryTokenResponse(
            accessToken: try Self.tokenSecret(resolvedToken),
            refreshToken: refreshToken,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(lifetime),
            grantedScopes: grantedScopes
        )
    }

    public func withAccessToken<Result>(
        _ body: (String) throws -> Result
    ) rethrows -> Result {
        try accessToken.withValue(body)
    }

    public func withRefreshToken<Result>(
        _ body: (String?) throws -> Result
    ) rethrows -> Result {
        if let refreshToken {
            return try refreshToken.withValue { try body($0) }
        }
        return try body(nil)
    }

    public func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }

    public func needsRefresh(
        at date: Date,
        minimumRemainingLifetime: TimeInterval = 30
    ) -> Bool {
        guard minimumRemainingLifetime.isFinite,
              minimumRemainingLifetime >= 0 else {
            return true
        }
        return date.addingTimeInterval(minimumRemainingLifetime) >= expiresAt
    }

    public var description: String {
        "RegistryTokenResponse(accessToken: [REDACTED], refreshToken: \(refreshToken == nil ? "absent" : "[REDACTED]"), issuedAt: \(issuedAt), expiresAt: \(expiresAt))"
    }

    public var debugDescription: String {
        description
    }

    private init(
        accessToken: RegistrySecret,
        refreshToken: RegistrySecret?,
        issuedAt: Date,
        expiresAt: Date,
        grantedScopes: RegistryAccessScopeSet?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.grantedScopes = grantedScopes
    }

    private static func tokenSecret(_ value: String) throws -> RegistrySecret {
        do {
            return try RegistrySecret(value)
        } catch {
            throw RegistryContractError.invalidTokenResponse(
                "Registry token response contains an empty or oversized token."
            )
        }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }
}

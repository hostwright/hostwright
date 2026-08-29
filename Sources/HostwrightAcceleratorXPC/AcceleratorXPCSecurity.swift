import Foundation
import Security
@preconcurrency import XPC

public enum AcceleratorXPCIdentityRole: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case daemon
    case client
    case service
}

public enum AcceleratorXPCIdentityPolicy {
    public static let teamIdentifier = "993YC3JY4Q"
    public static let serviceIdentifier = "dev.hostwright.phase10.accelerator-service"
    public static let daemonSigningIdentifier = "hostwrightd"
    public static let clientSigningIdentifiers: Set<String> = [
        daemonSigningIdentifier,
        "hostwright",
        "hostwright-control"
    ]
    public static let serviceEntitlementProjection: [String: Bool] = [
        "com.apple.security.app-sandbox": true
    ]
    public static let daemonEntitlementProjection: [String: Bool] = [:]
    public static let clientEntitlementProjection: [String: Bool] = [:]

    public static var serviceRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(serviceIdentifier)\" and entitlement[\"com.apple.security.app-sandbox\"]"
    }

    public static var daemonRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(daemonSigningIdentifier)\""
    }

    public static var clientRequirement: String {
        let identifiers = clientSigningIdentifiers.sorted()
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and (\(identifiers))"
    }

    public static func requirement(for role: AcceleratorXPCIdentityRole) -> String {
        switch role {
        case .daemon:
            daemonRequirement
        case .client:
            clientRequirement
        case .service:
            serviceRequirement
        }
    }

    public static func expectedIdentifier(for role: AcceleratorXPCIdentityRole) -> Set<String> {
        switch role {
        case .daemon:
            [daemonSigningIdentifier]
        case .client:
            clientSigningIdentifiers
        case .service:
            [serviceIdentifier]
        }
    }
}

public enum AcceleratorXPCIdentityError: Error, Equatable, Sendable {
    case invalidProof
    case invalidRole
    case identityUnavailable
    case teamMismatch
    case identifierMismatch
    case entitlementMismatch
    case codeDirectoryHashInvalid
    case requirementInvalid
    case requirementRejected
    case peerUnavailable
}

public struct AcceleratorXPCCodeIdentityProof:
    Codable,
    Equatable,
    Sendable
{
    public let teamIdentifier: String
    public let signingIdentifier: String
    public let codeDirectoryHash: String
    public let entitlementProjection: [String: Bool]

    public init(
        teamIdentifier: String,
        signingIdentifier: String,
        codeDirectoryHash: String,
        entitlementProjection: [String: Bool]
    ) throws {
        guard teamIdentifier == AcceleratorXPCIdentityPolicy.teamIdentifier,
              teamIdentifier.utf8.count == 10,
              signingIdentifier.utf8.count <= 128,
              !signingIdentifier.isEmpty,
              signingIdentifier.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                    || (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || scalar.value == 45 || scalar.value == 46 || scalar.value == 95
              }) else {
            throw AcceleratorXPCIdentityError.invalidProof
        }
        guard (codeDirectoryHash.count == 40 || codeDirectoryHash.count == 64),
              codeDirectoryHash.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw AcceleratorXPCIdentityError.codeDirectoryHashInvalid
        }
        guard entitlementProjection == AcceleratorXPCIdentityPolicy.serviceEntitlementProjection
            || entitlementProjection == AcceleratorXPCIdentityPolicy.daemonEntitlementProjection
            || entitlementProjection == AcceleratorXPCIdentityPolicy.clientEntitlementProjection else {
            throw AcceleratorXPCIdentityError.entitlementMismatch
        }
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.codeDirectoryHash = codeDirectoryHash
        self.entitlementProjection = entitlementProjection
    }

    public func validate(as role: AcceleratorXPCIdentityRole) throws {
        guard AcceleratorXPCIdentityPolicy.expectedIdentifier(for: role).contains(signingIdentifier) else {
            throw AcceleratorXPCIdentityError.identifierMismatch
        }
        guard teamIdentifier == AcceleratorXPCIdentityPolicy.teamIdentifier else {
            throw AcceleratorXPCIdentityError.teamMismatch
        }
        let expectedProjection: [String: Bool]
        switch role {
        case .service:
            expectedProjection = AcceleratorXPCIdentityPolicy.serviceEntitlementProjection
        case .daemon:
            expectedProjection = AcceleratorXPCIdentityPolicy.daemonEntitlementProjection
        case .client:
            expectedProjection = AcceleratorXPCIdentityPolicy.clientEntitlementProjection
        }
        guard entitlementProjection == expectedProjection else {
            throw AcceleratorXPCIdentityError.entitlementMismatch
        }
    }

    private enum CodingKeys: String, CodingKey {
        case teamIdentifier
        case signingIdentifier
        case codeDirectoryHash
        case entitlementProjection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys == Set(["teamIdentifier", "signingIdentifier", "codeDirectoryHash", "entitlementProjection"]) else {
            throw AcceleratorXPCIdentityError.invalidProof
        }
        try self.init(
            teamIdentifier: container.decode(String.self, forKey: .teamIdentifier),
            signingIdentifier: container.decode(String.self, forKey: .signingIdentifier),
            codeDirectoryHash: container.decode(String.self, forKey: .codeDirectoryHash),
            entitlementProjection: container.decode([String: Bool].self, forKey: .entitlementProjection)
        )
    }
}

public protocol AcceleratorXPCIdentityInspector: Sendable {
    func current() throws -> AcceleratorXPCCodeIdentityProof
    func peer(of connection: xpc_connection_t) throws -> AcceleratorXPCCodeIdentityProof
}

public struct AcceleratorXPCLiveIdentityInspector: AcceleratorXPCIdentityInspector, Sendable {
    public init() {}

    public func current() throws -> AcceleratorXPCCodeIdentityProof {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw AcceleratorXPCIdentityError.identityUnavailable
        }
        return try AcceleratorXPCSecCode.inspect(code)
    }

    public func peer(of connection: xpc_connection_t) throws -> AcceleratorXPCCodeIdentityProof {
        let processID = xpc_connection_get_pid(connection)
        guard processID > 0 else {
            throw AcceleratorXPCIdentityError.peerUnavailable
        }
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processID)
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            throw AcceleratorXPCIdentityError.peerUnavailable
        }
        return try AcceleratorXPCSecCode.inspect(code)
    }
}

public enum AcceleratorXPCSecCode {
    private static let revocationFlag = UInt32(1) << 30

    public static func validateCurrent(as role: AcceleratorXPCIdentityRole) throws -> AcceleratorXPCCodeIdentityProof {
        let proof = try AcceleratorXPCLiveIdentityInspector().current()
        try proof.validate(as: role)
        return proof
    }

    public static func validatePeer(
        _ connection: xpc_connection_t,
        as role: AcceleratorXPCIdentityRole
    ) throws -> AcceleratorXPCCodeIdentityProof {
        let proof = try AcceleratorXPCLiveIdentityInspector().peer(of: connection)
        try proof.validate(as: role)
        return proof
    }

    static func inspect(_ code: SecCode) throws -> AcceleratorXPCCodeIdentityProof {
        guard SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate | revocationFlag),
            nil
        ) == errSecSuccess else {
            throw AcceleratorXPCIdentityError.requirementRejected
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw AcceleratorXPCIdentityError.identityUnavailable
        }
        return try inspect(staticCode)
    }

    static func inspect(_ staticCode: SecStaticCode) throws -> AcceleratorXPCCodeIdentityProof {
        guard SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | revocationFlag),
            nil
        ) == errSecSuccess else {
            throw AcceleratorXPCIdentityError.requirementRejected
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [String: Any],
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let signingIdentifier = values[kSecCodeInfoIdentifier as String] as? String,
              let unique = values[kSecCodeInfoUnique as String] as? Data else {
            throw AcceleratorXPCIdentityError.identityUnavailable
        }
        return try proof(
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            unique: unique,
            entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        )
    }

    static func proof(
        teamIdentifier: String,
        signingIdentifier: String,
        unique: Data,
        entitlements: [String: Any]?
    ) throws -> AcceleratorXPCCodeIdentityProof {
        let entitlementValues = entitlements ?? [:]
        let entitlementProjection: [String: Bool]
        if let sandbox = entitlementValues["com.apple.security.app-sandbox"] {
            guard entitlementValues.count == 1, sandbox as? Bool == true else {
                throw AcceleratorXPCIdentityError.entitlementMismatch
            }
            entitlementProjection = AcceleratorXPCIdentityPolicy.serviceEntitlementProjection
        } else {
            guard entitlementValues.isEmpty else {
                throw AcceleratorXPCIdentityError.entitlementMismatch
            }
            entitlementProjection = AcceleratorXPCIdentityPolicy.daemonEntitlementProjection
        }
        return try AcceleratorXPCCodeIdentityProof(
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            codeDirectoryHash: unique.map { String(format: "%02x", $0) }.joined(),
            entitlementProjection: entitlementProjection
        )
    }
}

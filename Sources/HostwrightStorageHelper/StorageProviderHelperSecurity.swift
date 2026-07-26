import Darwin
import Foundation
import HostwrightStorage
import Security

private let storageHelperCodeSigningRevocationFlag: UInt32 =
    UInt32(1) << 30

public enum StorageProviderHelperAuthenticationError: Error, Equatable, Sendable {
    case peerCredentialsUnavailable
    case peerUserMismatch
    case peerProcessInvalid
    case peerCodeUnavailable
    case peerStaticCodeUnavailable
    case peerSigningInformationUnavailable
    case peerTeamMismatch
    case peerIdentifierRejected
    case peerCodeRequirementRejected
}

public enum StorageProviderHelperSecurity {
    public static let teamIdentifier =
        StorageProviderPeerIdentityPolicy.expectedTeamIdentifier
    public static let allowedClientIdentifiers: Set<String> = [
        "dev.hostwright.cli",
        "hostwright",
        "hostwright-control",
        "hostwrightd"
    ]

    public static func peerAuthenticator(
        expectedUserID: uid_t = geteuid()
    ) -> StorageProviderServerPeerAuthenticator {
        StorageProviderServerPeerAuthenticator { descriptor in
            try validatePeer(
                connectionDescriptor: descriptor,
                expectedUserID: expectedUserID
            )
        }
    }

    public static func validatePeer(
        connectionDescriptor: Int32,
        expectedUserID: uid_t
    ) throws {
        var peerUserID = uid_t.max
        var peerGroupID = gid_t.max
        guard getpeereid(
            connectionDescriptor,
            &peerUserID,
            &peerGroupID
        ) == 0 else {
            throw StorageProviderHelperAuthenticationError
                .peerCredentialsUnavailable
        }
        guard peerUserID == expectedUserID else {
            throw StorageProviderHelperAuthenticationError.peerUserMismatch
        }

        var peerProcessID = pid_t(0)
        var peerProcessIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            connectionDescriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerProcessID,
            &peerProcessIDSize
        ) == 0,
        peerProcessIDSize == MemoryLayout<pid_t>.size,
        peerProcessID > 0 else {
            throw StorageProviderHelperAuthenticationError.peerProcessInvalid
        }

        var code: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: peerProcessID)
        ] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &code
        ) == errSecSuccess,
        let code else {
            throw StorageProviderHelperAuthenticationError.peerCodeUnavailable
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw StorageProviderHelperAuthenticationError
                .peerStaticCodeUnavailable
        }

        var signingInformation: CFDictionary?
        let signingFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(
            staticCode,
            signingFlags,
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any] else {
            throw StorageProviderHelperAuthenticationError
                .peerSigningInformationUnavailable
        }
        guard information[kSecCodeInfoTeamIdentifier as String] as? String
            == teamIdentifier else {
            throw StorageProviderHelperAuthenticationError.peerTeamMismatch
        }
        guard let identifier =
                information[kSecCodeInfoIdentifier as String] as? String,
              allowedClientIdentifiers.contains(identifier) else {
            throw StorageProviderHelperAuthenticationError
                .peerIdentifierRejected
        }

        let requirementText =
            StorageProviderPeerIdentityPolicy.codeRequirementSource(
                identifier: identifier,
                teamIdentifier: teamIdentifier
            )
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement,
        SecCodeCheckValidity(
            code,
            SecCSFlags(
                rawValue:
                    kSecCSStrictValidate |
                    storageHelperCodeSigningRevocationFlag
            ),
            requirement
        ) == errSecSuccess else {
            throw StorageProviderHelperAuthenticationError
                .peerCodeRequirementRejected
        }
    }
}

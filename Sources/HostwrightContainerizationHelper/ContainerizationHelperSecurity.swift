import Darwin
import Foundation
import HostwrightRuntime
import Security

enum ContainerizationHelperAuthenticationError: Error, Equatable {
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

enum ContainerizationHelperSecurity {
    static let teamIdentifier = "993YC3JY4Q"

    // Command-line signing defaults use the executable name. The package-level
    // identifier remains accepted for qualification builds that set it explicitly.
    static let allowedClientIdentifiers: Set<String> = [
        "dev.hostwright.cli",
        "hostwright",
        "hostwright-control",
        "hostwrightd"
    ]

    static func peerAuthenticator(
        expectedUserID: uid_t = geteuid()
    ) -> ContainerizationHelperPeerAuthenticator {
        ContainerizationHelperPeerAuthenticator { descriptor in
            try validatePeer(connectionDescriptor: descriptor, expectedUserID: expectedUserID)
        }
    }

    static func validatePeer(
        connectionDescriptor: Int32,
        expectedUserID: uid_t
    ) throws {
        var peerUserID = uid_t.max
        var peerGroupID = gid_t.max
        guard getpeereid(connectionDescriptor, &peerUserID, &peerGroupID) == 0 else {
            throw ContainerizationHelperAuthenticationError.peerCredentialsUnavailable
        }
        guard peerUserID == expectedUserID else {
            throw ContainerizationHelperAuthenticationError.peerUserMismatch
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
            throw ContainerizationHelperAuthenticationError.peerProcessInvalid
        }

        var peerCode: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: peerProcessID)
        ] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peerCode) == errSecSuccess,
              let peerCode else {
            throw ContainerizationHelperAuthenticationError.peerCodeUnavailable
        }

        var peerStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(peerCode, [], &peerStaticCode) == errSecSuccess,
              let peerStaticCode else {
            throw ContainerizationHelperAuthenticationError.peerStaticCodeUnavailable
        }

        var signingInformation: CFDictionary?
        let signingFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(peerStaticCode, signingFlags, &signingInformation) == errSecSuccess,
              let signingInformation,
              let information = signingInformation as? [String: Any] else {
            throw ContainerizationHelperAuthenticationError.peerSigningInformationUnavailable
        }

        guard information[kSecCodeInfoTeamIdentifier as String] as? String == teamIdentifier else {
            throw ContainerizationHelperAuthenticationError.peerTeamMismatch
        }
        guard let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              allowedClientIdentifiers.contains(identifier) else {
            throw ContainerizationHelperAuthenticationError.peerIdentifierRejected
        }

        let requirementText =
            #"identifier \"\#(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\#(teamIdentifier)\""#
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else {
            throw ContainerizationHelperAuthenticationError.peerCodeRequirementRejected
        }

        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecCodeCheckValidity(peerCode, validationFlags, requirement) == errSecSuccess else {
            throw ContainerizationHelperAuthenticationError.peerCodeRequirementRejected
        }
    }
}

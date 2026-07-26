import Darwin
import Foundation
import Security

private let networkHelperCodeSigningRevocationFlag: UInt32 =
    UInt32(1) << 30

public enum NetworkHelperCodeIdentityError: Error, Equatable, Sendable {
    case credentialsUnavailable
    case userMismatch
    case processInvalid
    case processMismatch
    case codeUnavailable
    case staticCodeUnavailable
    case signingInformationUnavailable
    case teamMismatch
    case identifierRejected
    case requirementInvalid
    case requirementRejected
}

public enum NetworkHelperCodeIdentityPolicy {
    public static let teamIdentifier = "993YC3JY4Q"
    public static let helperIdentifier = "hostwright-network-helper"
    public static let allowedClientIdentifiers: Set<String> = [
        "dev.hostwright.cli",
        "hostwright",
        "hostwright-control",
        "hostwrightd"
    ]

    public static func requirementSource(
        identifier: String,
        teamIdentifier: String = teamIdentifier
    ) -> String {
        #"identifier "\#(identifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(teamIdentifier)""#
    }
}

public struct NetworkHelperPeerAuthenticator: Sendable {
    private let validation: @Sendable (Int32) throws -> Void

    public init(
        validation: @escaping @Sendable (Int32) throws -> Void
    ) {
        self.validation = validation
    }

    public func validate(connectionDescriptor: Int32) throws {
        try validation(connectionDescriptor)
    }

    public static func productionClient(
        expectedUserID: uid_t = geteuid()
    ) -> Self {
        Self { descriptor in
            let processID = try NetworkHelperPeerSecurity.validateSameUser(
                connectionDescriptor: descriptor,
                expectedUserID: expectedUserID
            )
            try NetworkHelperPeerSecurity.validateLiveProcess(
                processID: processID,
                allowedIdentifiers:
                    NetworkHelperCodeIdentityPolicy.allowedClientIdentifiers
            )
        }
    }
}

public struct NetworkHelperExecutableValidator: Sendable {
    private let validation: @Sendable (URL) throws -> Void

    public init(validation: @escaping @Sendable (URL) throws -> Void) {
        self.validation = validation
    }

    public func validate(executableURL: URL) throws {
        try validation(executableURL)
    }

    public static let production = Self { executableURL in
        try NetworkHelperPeerSecurity.validateStaticCode(
            executableURL: executableURL,
            expectedIdentifier:
                NetworkHelperCodeIdentityPolicy.helperIdentifier
        )
    }
}

public struct NetworkHelperServerPeerAuthenticator: Sendable {
    private let validation: @Sendable (Int32, pid_t) throws -> Void

    public init(
        validation: @escaping @Sendable (Int32, pid_t) throws -> Void
    ) {
        self.validation = validation
    }

    public func validate(
        connectionDescriptor: Int32,
        expectedProcessID: pid_t
    ) throws {
        try validation(connectionDescriptor, expectedProcessID)
    }

    public static func production(
        expectedUserID: uid_t = geteuid()
    ) -> Self {
        Self { descriptor, expectedProcessID in
            let processID = try NetworkHelperPeerSecurity.validateSameUser(
                connectionDescriptor: descriptor,
                expectedUserID: expectedUserID
            )
            guard processID == expectedProcessID else {
                throw NetworkHelperCodeIdentityError.processMismatch
            }
            try NetworkHelperPeerSecurity.validateLiveProcess(
                processID: processID,
                allowedIdentifiers: [
                    NetworkHelperCodeIdentityPolicy.helperIdentifier
                ]
            )
        }
    }
}

public enum NetworkHelperPeerSecurity {
    @discardableResult
    public static func validateSameUser(
        connectionDescriptor: Int32,
        expectedUserID: uid_t = geteuid()
    ) throws -> pid_t {
        var peerUserID = uid_t.max
        var peerGroupID = gid_t.max
        guard getpeereid(
            connectionDescriptor,
            &peerUserID,
            &peerGroupID
        ) == 0 else {
            throw NetworkHelperCodeIdentityError.credentialsUnavailable
        }
        guard peerUserID == expectedUserID else {
            throw NetworkHelperCodeIdentityError.userMismatch
        }
        return try peerProcessID(connectionDescriptor: connectionDescriptor)
    }

    public static func peerProcessID(
        connectionDescriptor: Int32
    ) throws -> pid_t {
        var processID = pid_t(0)
        var processIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            connectionDescriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &processID,
            &processIDSize
        ) == 0,
        processIDSize == MemoryLayout<pid_t>.size,
        processID > 0 else {
            throw NetworkHelperCodeIdentityError.processInvalid
        }
        return processID
    }

    public static func validateStaticCode(
        executableURL: URL,
        expectedIdentifier: String,
        expectedTeamIdentifier: String =
            NetworkHelperCodeIdentityPolicy.teamIdentifier
    ) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            throw NetworkHelperCodeIdentityError.staticCodeUnavailable
        }
        try validate(
            staticCode: staticCode,
            expectedIdentifiers: [expectedIdentifier],
            expectedTeamIdentifier: expectedTeamIdentifier
        )
    }

    public static func validateLiveProcess(
        processID: pid_t,
        allowedIdentifiers: Set<String>,
        expectedTeamIdentifier: String =
            NetworkHelperCodeIdentityPolicy.teamIdentifier
    ) throws {
        guard processID > 0 else {
            throw NetworkHelperCodeIdentityError.processInvalid
        }
        var code: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processID)
        ] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &code
        ) == errSecSuccess,
        let code else {
            throw NetworkHelperCodeIdentityError.codeUnavailable
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw NetworkHelperCodeIdentityError.staticCodeUnavailable
        }
        try validateSigningInformation(
            staticCode: staticCode,
            expectedIdentifiers: allowedIdentifiers,
            expectedTeamIdentifier: expectedTeamIdentifier
        )

        let information = try signingInformation(staticCode: staticCode)
        guard let identifier =
                information[kSecCodeInfoIdentifier as String] as? String else {
            throw NetworkHelperCodeIdentityError.identifierRejected
        }
        let requirement = try makeRequirement(
            identifier: identifier,
            teamIdentifier: expectedTeamIdentifier
        )
        let flags = SecCSFlags(
            rawValue:
                kSecCSStrictValidate |
                networkHelperCodeSigningRevocationFlag
        )
        guard SecCodeCheckValidity(code, flags, requirement) == errSecSuccess
        else {
            throw NetworkHelperCodeIdentityError.requirementRejected
        }
    }

    private static func validate(
        staticCode: SecStaticCode,
        expectedIdentifiers: Set<String>,
        expectedTeamIdentifier: String
    ) throws {
        try validateSigningInformation(
            staticCode: staticCode,
            expectedIdentifiers: expectedIdentifiers,
            expectedTeamIdentifier: expectedTeamIdentifier
        )
        let information = try signingInformation(staticCode: staticCode)
        guard let identifier =
                information[kSecCodeInfoIdentifier as String] as? String else {
            throw NetworkHelperCodeIdentityError.identifierRejected
        }
        let requirement = try makeRequirement(
            identifier: identifier,
            teamIdentifier: expectedTeamIdentifier
        )
        let flags = SecCSFlags(
            rawValue:
                kSecCSStrictValidate |
                networkHelperCodeSigningRevocationFlag
        )
        guard SecStaticCodeCheckValidity(
            staticCode,
            flags,
            requirement
        ) == errSecSuccess else {
            throw NetworkHelperCodeIdentityError.requirementRejected
        }
    }

    private static func validateSigningInformation(
        staticCode: SecStaticCode,
        expectedIdentifiers: Set<String>,
        expectedTeamIdentifier: String
    ) throws {
        let information = try signingInformation(staticCode: staticCode)
        guard information[kSecCodeInfoTeamIdentifier as String] as? String
            == expectedTeamIdentifier else {
            throw NetworkHelperCodeIdentityError.teamMismatch
        }
        guard let identifier =
                information[kSecCodeInfoIdentifier as String] as? String,
              expectedIdentifiers.contains(identifier) else {
            throw NetworkHelperCodeIdentityError.identifierRejected
        }
    }

    private static func signingInformation(
        staticCode: SecStaticCode
    ) throws -> [String: Any] {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [String: Any] else {
            throw NetworkHelperCodeIdentityError
                .signingInformationUnavailable
        }
        return dictionary
    }

    private static func makeRequirement(
        identifier: String,
        teamIdentifier: String
    ) throws -> SecRequirement {
        let source = NetworkHelperCodeIdentityPolicy.requirementSource(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            source as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else {
            throw NetworkHelperCodeIdentityError.requirementInvalid
        }
        return requirement
    }
}

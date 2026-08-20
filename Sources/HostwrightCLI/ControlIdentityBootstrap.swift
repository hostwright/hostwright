import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightCore
import HostwrightState

enum HostwrightControlIdentityBootstrap {
    static func bootstrapCurrentProcess() throws {
        try bootstrap(
            installerIdentity: DarwinCurrentControlCodeIdentity.inspect(),
            companionIdentity: nil
        )
    }

    static func bootstrapAPIProcesses() throws {
        try bootstrap(
            installerIdentity: DarwinCurrentControlCodeIdentity.inspect(processID: getppid()),
            companionIdentity: DarwinCurrentControlCodeIdentity.inspect()
        )
    }

    private static func bootstrap(
        installerIdentity: CodeIdentity,
        companionIdentity: CodeIdentity?
    ) throws {
        let resolution = try HostwrightLocalPathResolver.resolve()
        let store = SQLiteStateStore(
            configuration: StateStoreConfiguration(localPathResolution: resolution)
        )
        _ = try StateUpgradeService(store: store).migrateToLatestWithVerifiedBackup()
        try bootstrap(
            store: store,
            userID: UInt32(geteuid()),
            codeIdentity: installerIdentity,
            companionIdentity: companionIdentity,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func bootstrap(
        store: SQLiteStateStore,
        userID: UInt32,
        codeIdentity: CodeIdentity,
        companionIdentity: CodeIdentity? = nil,
        timestamp: String
    ) throws {
        try validateBootstrapPair(
            installer: codeIdentity,
            companion: companionIdentity
        )
        let identities = try store.controlIdentities.listIdentities()
        if identities.isEmpty {
            let subjectID = "owner-\(userID)-\(codeIdentity.codeDirectoryHash.prefix(16))"
            try store.controlIdentities.bootstrap(
                ControlPeerIdentityRecord(
                    subjectID: subjectID,
                    userID: userID,
                    codeIdentity: codeIdentity,
                    declaredBySubjectID: subjectID,
                    declaredAt: timestamp,
                    updatedAt: timestamp
                )
            )
            try store.rbac.bootstrapDefaultRolesAndOwner(
                subjectID: subjectID,
                timestamp: timestamp
            )
            if let companionIdentity {
                try store.controlIdentities.declare(
                    ControlPeerIdentityRecord(
                        subjectID:
                            "bootstrap-companion-\(userID)-\(companionIdentity.codeDirectoryHash.prefix(16))",
                        userID: userID,
                        codeIdentity: companionIdentity,
                        declaredBySubjectID: subjectID,
                        declaredAt: timestamp,
                        updatedAt: timestamp
                    )
                )
            }
            return
        }
        let current = try resolveOrRotate(
            store: store,
            identities: identities,
            userID: userID,
            currentIdentity: codeIdentity,
            declaringSubjectID: nil,
            timestamp: timestamp
        )
        try store.rbac.bootstrapDefaultRolesAndOwner(
            subjectID: current.subjectID,
            timestamp: timestamp
        )
        if let companionIdentity {
            _ = try resolveOrRotate(
                store: store,
                identities: try store.controlIdentities.listIdentities(),
                userID: userID,
                currentIdentity: companionIdentity,
                declaringSubjectID: current.subjectID,
                timestamp: timestamp
            )
        }
    }

    private static func validateBootstrapPair(
        installer: CodeIdentity,
        companion: CodeIdentity?
    ) throws {
        try installer.validate()
        let installerIdentifierAllowed: Bool
        switch installer.validationMode {
        case .installedRequirement:
            installerIdentifierAllowed = ["hostwright", "dev.hostwright.cli"]
                .contains(installer.signingIdentifier)
        case .pinnedAdHoc:
            installerIdentifierAllowed = installer.signingIdentifier == "dev.hostwright.cli"
                || adHocIdentifier(installer.signingIdentifier, base: "hostwright")
        }
        guard installerIdentifierAllowed else {
            throw StateStoreError.invalidRecord(
                "The bootstrap installer code identity is not Hostwright CLI."
            )
        }
        guard let companion else { return }
        try companion.validate()
        let companionIdentifierAllowed = companion.validationMode == .installedRequirement
            ? companion.signingIdentifier == "hostwright-control"
            : adHocIdentifier(companion.signingIdentifier, base: "hostwright-control")
        guard companionIdentifierAllowed,
              companion.validationMode == installer.validationMode,
              companion.teamIdentifier == installer.teamIdentifier else {
            throw StateStoreError.invalidRecord(
                "The bootstrap companion code identity does not match the installer trust domain."
            )
        }
        if installer.validationMode == .installedRequirement {
            guard installer.teamIdentifier == ControlPeerTrustPolicy.installedTeamIdentifier else {
                throw StateStoreError.invalidRecord(
                    "The bootstrap installer team identity is not trusted."
                )
            }
        }
    }

    private static func adHocIdentifier(_ value: String, base: String) -> Bool {
        value == base || value.range(
            of: "^\(NSRegularExpression.escapedPattern(for: base))-[a-f0-9]{40}$",
            options: .regularExpression
        ) != nil
    }

    private static func resolveOrRotate(
        store: SQLiteStateStore,
        identities: [ControlPeerIdentityRecord],
        userID: UInt32,
        currentIdentity: CodeIdentity,
        declaringSubjectID: String?,
        timestamp: String
    ) throws -> ControlPeerIdentityRecord {
        let exact = identities.filter {
            $0.userID == userID && $0.revokedAt == nil
                && matchesExactly($0.codeIdentity, currentIdentity)
        }
        guard exact.count <= 1 else {
            throw StateStoreError.transactionInvariantViolation(
                message: "The exact active control identity is ambiguous."
            )
        }
        if let exact = exact.first { return exact }

        guard currentIdentity.validationMode == .installedRequirement else {
            throw StateStoreError.invalidRecord(
                declaringSubjectID == nil
                    ? "The installing process is not an active declared control identity."
                    : "The ad-hoc bootstrap companion is not an active declared control identity."
            )
        }
        let bucket = identities.filter {
            $0.userID == userID && $0.revokedAt == nil
                && $0.codeIdentity.validationMode == .installedRequirement
                && $0.codeIdentity.teamIdentifier == currentIdentity.teamIdentifier
                && $0.codeIdentity.signingIdentifier == currentIdentity.signingIdentifier
        }
        guard bucket.count <= 1 else {
            throw StateStoreError.transactionInvariantViolation(
                message: "The installed control identity bucket is ambiguous."
            )
        }
        if let existing = bucket.first {
            return try store.controlIdentities.rotateInstalledCodeIdentity(
                subjectID: existing.subjectID,
                expectedGeneration: existing.generation,
                replacement: currentIdentity,
                updatedAt: timestamp
            )
        }
        guard let declaringSubjectID else {
            throw StateStoreError.invalidRecord(
                "The installing process is not an active declared control identity."
            )
        }
        let declared = ControlPeerIdentityRecord(
            subjectID:
                "bootstrap-companion-\(userID)-\(currentIdentity.codeDirectoryHash.prefix(16))",
            userID: userID,
            codeIdentity: currentIdentity,
            declaredBySubjectID: declaringSubjectID,
            declaredAt: timestamp,
            updatedAt: timestamp
        )
        try store.controlIdentities.declare(declared)
        return declared
    }

    private static func matchesExactly(
        _ declared: CodeIdentity,
        _ current: CodeIdentity
    ) -> Bool {
        declared.validationMode == current.validationMode
            && declared.teamIdentifier == current.teamIdentifier
            && declared.signingIdentifier == current.signingIdentifier
            && declared.codeDirectoryHash == current.codeDirectoryHash
    }
}

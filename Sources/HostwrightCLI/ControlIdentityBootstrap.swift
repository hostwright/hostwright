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
        let installerProcessID = getppid()
        try bootstrap(
            installerIdentity: DarwinCurrentControlCodeIdentity.inspect(processID: installerProcessID),
            companionIdentity: DarwinCurrentControlCodeIdentity.inspect(),
            desktopIdentity: try discoverDesktopIdentity(installerProcessID: installerProcessID)
        )
    }

    private static func bootstrap(
        installerIdentity: CodeIdentity,
        companionIdentity: CodeIdentity?,
        desktopIdentity: CodeIdentity? = nil
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
            desktopIdentity: desktopIdentity,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func bootstrap(
        store: SQLiteStateStore,
        userID: UInt32,
        codeIdentity: CodeIdentity,
        companionIdentity: CodeIdentity? = nil,
        desktopIdentity: CodeIdentity? = nil,
        timestamp: String
    ) throws {
        try validateBootstrapPair(
            installer: codeIdentity,
            companion: companionIdentity,
            desktop: desktopIdentity
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
            if let desktopIdentity {
                let desktop = try declareCompanion(
                    store: store,
                    userID: userID,
                    identity: desktopIdentity,
                    declaringSubjectID: subjectID,
                    timestamp: timestamp
                )
                try ensureDesktopOperatorBinding(
                    store: store,
                    desktop: desktop,
                    ownerSubjectID: subjectID,
                    timestamp: timestamp
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
        if let desktopIdentity {
            let desktop = try resolveOrRotate(
                store: store,
                identities: try store.controlIdentities.listIdentities(),
                userID: userID,
                currentIdentity: desktopIdentity,
                declaringSubjectID: current.subjectID,
                timestamp: timestamp
            )
            try ensureDesktopOperatorBinding(
                store: store,
                desktop: desktop,
                ownerSubjectID: current.subjectID,
                timestamp: timestamp
            )
        }
    }

    private static func validateBootstrapPair(
        installer: CodeIdentity,
        companion: CodeIdentity?,
        desktop: CodeIdentity?
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
        if let companion {
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
        }
        if installer.validationMode == .installedRequirement {
            guard installer.teamIdentifier == ControlPeerTrustPolicy.installedTeamIdentifier else {
                throw StateStoreError.invalidRecord(
                    "The bootstrap installer team identity is not trusted."
                )
            }
        }
        guard let desktop else { return }
        try desktop.validate()
        let desktopIdentifierAllowed = desktop.validationMode == .installedRequirement
            ? desktop.signingIdentifier == "dev.hostwright.desktop"
            : adHocIdentifier(desktop.signingIdentifier, base: "hostwright-desktop")
        guard desktopIdentifierAllowed,
              desktop.validationMode == installer.validationMode,
              desktop.teamIdentifier == installer.teamIdentifier else {
            throw StateStoreError.invalidRecord(
                "The bootstrap desktop identity does not match the installer trust domain."
            )
        }
    }

    private static func declareCompanion(
        store: SQLiteStateStore,
        userID: UInt32,
        identity: CodeIdentity,
        declaringSubjectID: String,
        timestamp: String
    ) throws -> ControlPeerIdentityRecord {
        let record = ControlPeerIdentityRecord(
            subjectID: "bootstrap-companion-\(userID)-\(identity.codeDirectoryHash.prefix(16))",
            userID: userID,
            codeIdentity: identity,
            declaredBySubjectID: declaringSubjectID,
            declaredAt: timestamp,
            updatedAt: timestamp
        )
        try store.controlIdentities.declare(record)
        return record
    }

    private static func ensureDesktopOperatorBinding(
        store: SQLiteStateStore,
        desktop: ControlPeerIdentityRecord,
        ownerSubjectID: String,
        timestamp: String
    ) throws {
        let bindingID = "desktop-operator-\(desktop.subjectID)"
        let expected = RBACBindingRecord(
            bindingID: bindingID,
            subjectID: desktop.subjectID,
            roleID: DefaultRole.operator.rawValue,
            scope: RBACScope(kind: .global),
            createdBySubjectID: ownerSubjectID,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        if let existing = try store.rbac.binding(id: bindingID) {
            guard existing.subjectID == expected.subjectID,
                  existing.roleID == expected.roleID,
                  existing.scope == expected.scope,
                  existing.createdBySubjectID == expected.createdBySubjectID else {
                throw StateStoreError.transactionInvariantViolation(
                    message: "The desktop operator binding differs from the trusted bootstrap record."
                )
            }
            return
        }
        _ = try store.rbac.createBinding(expected)
    }

    private static func discoverDesktopIdentity(installerProcessID: pid_t) throws -> CodeIdentity? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let count = proc_pidpath(installerProcessID, &buffer, UInt32(buffer.count))
        guard count > 0 else { throw ControlPeerAuthenticationError.codeUnavailable }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let installerURL = URL(
            fileURLWithPath: String(decoding: pathBytes, as: UTF8.self)
        ).standardizedFileURL
        let directory = installerURL.deletingLastPathComponent()
        let candidate = directory.lastPathComponent == "bin"
            ? directory.deletingLastPathComponent().appendingPathComponent(
                "libexec/hostwright/Hostwright.app/Contents/MacOS/hostwright-desktop"
            )
            : directory.appendingPathComponent("hostwright-desktop")
        var status = stat()
        guard lstat(candidate.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw ControlPeerAuthenticationError.codeUnavailable
        }
        return try DarwinCurrentControlCodeIdentity.inspect(executablePath: candidate.path)
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

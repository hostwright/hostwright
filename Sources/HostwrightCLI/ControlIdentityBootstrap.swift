import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightCore
import HostwrightState

enum HostwrightControlIdentityBootstrap {
    static func bootstrapCurrentProcess() throws {
        let resolution = try HostwrightLocalPathResolver.resolve()
        let store = SQLiteStateStore(
            configuration: StateStoreConfiguration(localPathResolution: resolution)
        )
        _ = try StateUpgradeService(store: store).migrateToLatestWithVerifiedBackup()
        try bootstrap(
            store: store,
            userID: UInt32(geteuid()),
            codeIdentity: DarwinCurrentControlCodeIdentity.inspect(),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func bootstrap(
        store: SQLiteStateStore,
        userID: UInt32,
        codeIdentity: CodeIdentity,
        timestamp: String
    ) throws {
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
            return
        }
        guard identities.contains(where: {
            $0.userID == userID && $0.revokedAt == nil && matches($0.codeIdentity, codeIdentity)
        }) else {
            throw StateStoreError.invalidRecord(
                "The installing process is not an active declared control identity."
            )
        }
    }

    private static func matches(_ declared: CodeIdentity, _ current: CodeIdentity) -> Bool {
        guard declared.validationMode == current.validationMode else { return false }
        switch current.validationMode {
        case .installedRequirement:
            return declared.teamIdentifier == current.teamIdentifier
                && declared.signingIdentifier == current.signingIdentifier
        case .pinnedAdHoc:
            return declared.teamIdentifier == nil
                && declared.signingIdentifier == current.signingIdentifier
                && declared.codeDirectoryHash == current.codeDirectoryHash
        }
    }
}

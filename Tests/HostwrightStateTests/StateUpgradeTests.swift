import Foundation
import CryptoKit
import HostwrightControlPlane
import Synchronization
import XCTest
@testable import HostwrightCore
@testable import HostwrightState

final class StateUpgradeTests: XCTestCase {
    func testBootstrapContinuityRejectsRetainedExternalAuthorityBeforeLegacyMigration() throws {
        try withTemporaryStore(throughVersion: 7) { store, _ in
            let keys = InMemoryAuditSigningKeyStore()
            XCTAssertNoThrow(try store.verifyIdentityBootstrapContinuity(keyStore: keys, requireEmptyAuthority: true))
            _ = try keys.activeKey()
            let before = try Data(contentsOf: URL(fileURLWithPath: store.path))
            XCTAssertThrowsError(try store.verifyIdentityBootstrapContinuity(keyStore: keys, requireEmptyAuthority: true))
            XCTAssertEqual(try store.schemaVersion(), 7)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), before)
            XCTAssertNotNil(try keys.configuredActiveKey())
        }
    }

    func testBootstrapContinuityRejectsCorruptModernAuditWithEmptyIdentities() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let keys = InMemoryAuditSigningKeyStore()
            let trail = TamperEvidentAuditTrail(store: store, keyStore: keys)
            _ = try trail.append(AuditAppendInput(subjectID: "owner", requestID: "audit-preflight",
                action: .authentication, outcome: "accepted", reasonCode: "accepted",
                payloadDigest: "sha256:" + String(repeating: "a", count: 64)))
            XCTAssertFalse(try store.controlIdentities.hasEstablishedIdentityAuthority())
            XCTAssertNoThrow(try store.verifyIdentityBootstrapContinuity(keyStore: keys))
            try keys.clearHead()
            XCTAssertThrowsError(try store.verifyIdentityBootstrapContinuity(keyStore: keys))
            XCTAssertNil(try keys.loadHead())
            XCTAssertFalse(try store.controlIdentities.hasEstablishedIdentityAuthority())
        }
    }

    func testAbsentUninstallRecoveryRequiresExactSnapshotAuditAnchor() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, directory in
            let keys = InMemoryAuditSigningKeyStore()
            let trail = TamperEvidentAuditTrail(store: store, keyStore: keys)
            let service = StateUpgradeService(store: store)
            func append(_ id: String) throws {
                _ = try trail.append(AuditAppendInput(subjectID: "owner", requestID: id,
                    action: .authentication, outcome: "accepted", reasonCode: "accepted",
                    payloadDigest: "sha256:" + String(repeating: "a", count: 64)))
            }
            try append("uninstall-A")
            let stale = try service.createVerifiedSnapshot(at: directory.appendingPathComponent("stale.sqlite").path)
            try append("uninstall-B")
            let current = try service.createVerifiedSnapshot(at: directory.appendingPathComponent("current.sqlite").path)
            let head = try keys.loadHead()
            _ = try StateDatabaseRemovalService(store: store).removeVerifiedDatabase()
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
            XCTAssertThrowsError(try service.restoreVerifiedSnapshotPreservingAudit(current,
                operationID: UUID().uuidString.lowercased(), keyStore: keys))
            XCTAssertThrowsError(try service.restoreVerifiedSnapshotPreservingAudit(stale,
                operationID: UUID().uuidString.lowercased(), keyStore: keys,
                allowAbsentCurrentStateForUninstallRecovery: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
            XCTAssertEqual(try keys.loadHead(), head)
            let preservedEntries = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            _ = try service.restoreVerifiedSnapshotPreservingAudit(current,
                operationID: UUID().uuidString.lowercased(), keyStore: keys,
                allowAbsentCurrentStateForUninstallRecovery: true)
            XCTAssertEqual(trail.verify().health, .healthy)
            XCTAssertEqual(trail.verify().recordCount, 2)
            XCTAssertEqual(try keys.loadHead(), head)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                preservedEntries.union(["state.sqlite"]))
        }
    }

    func testAbsentUninstallRecoveryPublishesOnlyRevokedSessionsAndCredentialsBeforeInterruption() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, directory in
            let keys = InMemoryAuditSigningKeyStore()
            let code = CodeIdentity(teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.owner",
                codeDirectoryHash: String(repeating: "a", count: 64), validationMode: .installedRequirement)
            let timestamp = "2026-09-13T17:00:00Z"
            try store.controlIdentities.bootstrap(ControlPeerIdentityRecord(subjectID: "owner", userID: 501,
                codeIdentity: code, declaredBySubjectID: "owner", declaredAt: timestamp, updatedAt: timestamp))
            let peerCode = CodeIdentity(teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.peer",
                codeDirectoryHash: String(repeating: "b", count: 64), validationMode: .installedRequirement)
            let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
            try store.controlIdentities.declare(ControlPeerIdentityRecord(subjectID: "peer", userID: 501,
                codeIdentity: peerCode, credentialID: "old-credential", credentialPublicKeyBase64: publicKey,
                declaredBySubjectID: "owner", declaredAt: timestamp, updatedAt: timestamp))
            let session = ControlSessionRecord(sessionID: "old-session", subjectID: "peer", daemonGeneration: 1,
                serverNonceSHA256: String(repeating: "f", count: 64), socketDevice: 1, socketInode: 2,
                effectiveUID: 501, effectiveGID: 20, pid: 123, pidVersion: 1, auditSessionID: 1,
                codeDirectoryHash: peerCode.codeDirectoryHash, credentialID: "old-credential",
                createdAt: timestamp, expiresAt: "2026-09-13T23:00:00Z", updatedAt: timestamp)
            try store.controlIdentities.persistSession(session)
            let trail = TamperEvidentAuditTrail(store: store, keyStore: keys)
            _ = try trail.append(AuditAppendInput(subjectID: "owner", requestID: "before-uninstall",
                action: .authentication, outcome: "accepted", reasonCode: "accepted",
                payloadDigest: "sha256:" + String(repeating: "a", count: 64)))
            let snapshot = try StateUpgradeService(store: store).createVerifiedSnapshot(
                at: directory.appendingPathComponent("captured.sqlite").path)
            let head = try keys.loadHead()
            _ = try StateDatabaseRemovalService(store: store).removeVerifiedDatabase()
            let preservedEntries = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            XCTAssertThrowsError(try StateUpgradeService(store: store, testInterruption: .afterRestorePublishedAndVerified)
                .restoreVerifiedSnapshotPreservingAudit(snapshot, operationID: UUID().uuidString.lowercased(),
                    keyStore: keys, allowAbsentCurrentStateForUninstallRecovery: true)) { error in
                XCTAssertEqual(error as? StateUpgradeTestInterruption, .afterRestorePublishedAndVerified, String(describing: error))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
            XCTAssertTrue(try store.controlIdentities.listSessions().allSatisfy { $0.revokedAt != nil })
            XCTAssertNotNil(try store.controlIdentities.listIdentities().first { $0.subjectID == "peer" }?.revokedAt)
            XCTAssertThrowsError(try store.controlIdentities.validateActiveSession("old-session", daemonGeneration: 1,
                at: "2026-09-13T18:00:00Z"))
            XCTAssertThrowsError(try store.controlIdentities.declare(ControlPeerIdentityRecord(subjectID: "replacement-peer",
                userID: 501, codeIdentity: peerCode, credentialID: "old-credential", credentialPublicKeyBase64: publicKey,
                declaredBySubjectID: "owner", declaredAt: timestamp, updatedAt: timestamp)))
            XCTAssertEqual(trail.verify().health, .healthy)
            XCTAssertEqual(try keys.loadHead(), head)
            let finalEntries = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            let lifecycleLock = (try store.configuration.maintenancePaths().accessLockPath as NSString).lastPathComponent + ".lifecycle-mutation"
            XCTAssertTrue(preservedEntries.isSubset(of: finalEntries))
            XCTAssertTrue(finalEntries.isSubset(of: preservedEntries.union([
                "state.sqlite", "state.sqlite-wal", "state.sqlite-shm", lifecycleLock
            ])))
        }
    }

    func testIdentityAuthorityInspectionDoesNotMigrateCompatibleOlderStores() throws {
        for version in [7, 18, MigrationRunner.latestSchemaVersion] {
            try withTemporaryStore(throughVersion: version) { store, _ in
                XCTAssertFalse(try store.controlIdentities.hasEstablishedIdentityAuthority())
                XCTAssertEqual(try store.schemaVersion(), version)
            }
        }
    }

    func testAuditContinuousRollbackRestoresStateAndRetainsNewerExternalHead() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, directory in
            let keys = InMemoryAuditSigningKeyStore()
            let trail = TamperEvidentAuditTrail(store: store, keyStore: keys)
            func input(_ id: String) -> AuditAppendInput {
                AuditAppendInput(subjectID: "owner", requestID: id, action: .authentication,
                    outcome: "accepted", reasonCode: "accepted",
                    payloadDigest: "sha256:" + String(repeating: "a", count: 64))
            }
            let codeA = CodeIdentity(teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.client",
                codeDirectoryHash: String(repeating: "a", count: 64), validationMode: .installedRequirement)
            let codeB = CodeIdentity(teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.client",
                codeDirectoryHash: String(repeating: "b", count: 64), validationMode: .installedRequirement)
            let credentialKey = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
            let owner = ControlPeerIdentityRecord(subjectID: "owner", userID: 501, codeIdentity: codeA,
                declaredBySubjectID: "owner", declaredAt: "2026-08-02T20:00:00Z", updatedAt: "2026-08-02T20:00:00Z")
            XCTAssertFalse(try store.controlIdentities.hasEstablishedIdentityAuthority())
            try store.controlIdentities.bootstrap(owner)
            XCTAssertTrue(try store.controlIdentities.hasEstablishedIdentityAuthority())
            try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: "2026-08-02T20:00:00Z")
            let proofCode = CodeIdentity(teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.proof-peer",
                codeDirectoryHash: String(repeating: "c", count: 64), validationMode: .installedRequirement)
            let proofPeer = ControlPeerIdentityRecord(subjectID: "proof-peer", userID: 501, codeIdentity: proofCode,
                credentialID: "credential-A", credentialPublicKeyBase64: credentialKey,
                declaredBySubjectID: "owner", declaredAt: "2026-08-02T20:00:00Z", updatedAt: "2026-08-02T20:00:00Z")
            try store.controlIdentities.declare(proofPeer)
            let removedBinding = try store.rbac.createBinding(RBACBindingRecord(bindingID: "removed-in-B", subjectID: "owner",
                roleID: "viewer", scope: RBACScope(kind: .global), createdBySubjectID: "owner",
                createdAt: "2026-08-02T20:00:00Z", updatedAt: "2026-08-02T20:00:00Z"))
            let pluginDigest = "sha256:" + String(repeating: "e", count: 64)
            try store.withConnection { connection in
                try connection.run("""
                    INSERT INTO plugin_packages (package_digest,plugin_identifier,package_version,hostwright_compatibility,
                        provider_kind,entrypoint,artifact_digest,manifest_json,manifest_digest,cms_signature,signer_identifier,
                        storage_path,ownership_ledger_json,lifecycle_state,generation,created_by_subject_id,created_at,updated_at)
                    VALUES (?, 'fixture.plugin', '1.0.0', '0.0.2', 'wasi', 'main.wasm', ?, '{}', ?, 'retention-fixture-signature',
                        'fixture-signer', '/private/fixture/plugin', '[]', 'verified', 1, 'owner', '2026-08-02T20:00:00Z', '2026-08-02T20:00:00Z')
                    """, bindings: [.text(pluginDigest), .text(pluginDigest), .text(pluginDigest)])
                try connection.run("""
                    INSERT INTO plugin_provenance VALUES (?, ?, 'retention-fixture-signature', 'fixture-signer',
                        'localDirectory', '/private/fixture/plugin', '{}', '2026-08-02T20:00:00Z')
                    """, bindings: [.text(pluginDigest), .text(pluginDigest)])
                try connection.run("""
                    INSERT INTO plugin_grants VALUES (?, 'diagnostics', 'global', 'owner', 'fixture-approval', '2026-08-02T20:00:00Z', NULL)
                    """, bindings: [.text(pluginDigest)])
            }
            func session(_ id: String, code: CodeIdentity) -> ControlSessionRecord {
                ControlSessionRecord(sessionID: id, subjectID: "owner", daemonGeneration: 1,
                    serverNonceSHA256: String(repeating: "f", count: 64), socketDevice: 1, socketInode: 2,
                    effectiveUID: 501, effectiveGID: 20, pid: 123, pidVersion: 1, auditSessionID: 1,
                    codeDirectoryHash: code.codeDirectoryHash, createdAt: "2026-08-02T20:00:00Z",
                    expiresAt: "2026-08-02T22:00:00Z", updatedAt: "2026-08-02T20:00:00Z")
            }
            let oldA = session("old-A-session", code: codeA)
            try store.controlIdentities.persistSession(oldA)
            _ = try trail.append(input("release-A"))
            let snapshotDirectory = directory.appendingPathComponent("rollback")
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let service = StateUpgradeService(store: store)
            let snapshot = try service.createVerifiedSnapshot(at: snapshotDirectory.appendingPathComponent("state.sqlite").path)
            try store.withConnection { connection in
                try connection.run("INSERT INTO projects (id,name,manifest_hash,created_at,updated_at) VALUES ('B-only','B','B','2026-08-01T12:00:00Z','2026-08-01T12:00:00Z')")
            }
            func constrainedProfile(_ identifier: String, parent: String? = nil) -> WorkloadProfile {
                WorkloadProfile(identifier: identifier, parent: parent,
                    filesystem: FilesystemProfile(readOnlyRoot: true, denyHostRoot: true),
                    network: NetworkProfile(mode: .isolated), secrets: SecretsProfile(),
                    images: ImagesProfile(requireDigest: true, requireSignature: false), runtime: RuntimeProfile(),
                    hostAccess: HostAccessProfile(allowed: false),
                    observability: ObservabilityProfile(logs: false, metrics: false, traces: false),
                    accelerators: AcceleratorsProfile(), syscalls: SyscallProfile(defaultDeny: false))
            }
            for profile in [constrainedProfile("B-policy"), constrainedProfile("B-child", parent: "B-policy")] {
                _ = try store.workloadProfiles.create(WorkloadProfileRecord(profile: profile,
                    createdBySubjectID: "owner", createdAt: "2026-08-02T20:01:00Z", updatedAt: "2026-08-02T20:01:00Z"))
            }
            let newerProfiles = try store.workloadProfiles.listProfiles()
            try store.rbac.deleteBinding(id: removedBinding.bindingID, expectedGeneration: removedBinding.generation)
            try store.withConnection { try $0.run("UPDATE plugin_grants SET revoked_at='2026-08-02T20:01:00Z' WHERE package_digest=?", bindings: [.text(pluginDigest)]) }
            let rotated = try store.controlIdentities.rotateInstalledCodeIdentity(subjectID: owner.subjectID,
                expectedGeneration: owner.generation, replacement: codeB, updatedAt: "2026-08-02T20:01:00Z")
            _ = try store.controlIdentities.rotateCredential(subjectID: proofPeer.subjectID,
                expectedGeneration: proofPeer.generation, credentialID: "credential-B", credentialPublicKeyBase64: credentialKey,
                credentialExpiresAt: nil, updatedAt: "2026-08-02T20:02:00Z")
            try store.controlIdentities.revoke(ControlIdentityRevocationRecord(revocationID: "revoked-old-A-credential",
                targetKind: .credential, targetIdentifier: "credential-A", reason: "credential A was replaced",
                actorSubjectID: "owner", revokedAt: "2026-08-02T20:02:00Z"))
            XCTAssertThrowsError(try store.controlIdentities.rotateInstalledCodeIdentity(subjectID: owner.subjectID,
                expectedGeneration: rotated.generation, replacement: codeA, updatedAt: "2026-08-02T20:02:00Z"))
            let oldB = session("old-B-session", code: codeB)
            try store.controlIdentities.persistSession(oldB)
            _ = try trail.append(input("release-B"))
            let newerHead = try keys.loadHead()
            func checked<T>(_ stage: String, _ body: () throws -> T) throws -> T {
                do { return try body() }
                catch { throw StateMaintenanceError.recoveryFailed("rollback regression stage \(stage): \(String(describing: error))") }
            }
            let operationID = "00000000-0000-0000-0000-000000000007"
            _ = try checked("restore") { try service.restoreVerifiedSnapshotPreservingAudit(snapshot,
                operationID: operationID, keyStore: keys, approvedInstalledCodeIdentities: [codeA], expectedCurrentInstalledCodeIdentities: [codeB]) }
            XCTAssertEqual(try keys.loadHead(), newerHead)
            XCTAssertEqual(trail.verify().health, .healthy)
            XCTAssertEqual(trail.verify().recordCount, 2)
            XCTAssertEqual(try store.withConnection(readOnly: true) { try $0.query("SELECT id FROM projects WHERE id='B-only'") }, [])
            // Retrying recovery must retain the same chain rather than rewind its external anchor.
            _ = try checked("restore") { try service.restoreVerifiedSnapshotPreservingAudit(snapshot,
                operationID: operationID, keyStore: keys, approvedInstalledCodeIdentities: [codeA], expectedCurrentInstalledCodeIdentities: [codeB]) }
            XCTAssertEqual(try keys.loadHead(), newerHead)
            XCTAssertEqual(try store.controlIdentities.loadIdentity("owner")?.codeIdentity, codeA)
            XCTAssertNil(try store.rbac.binding(id: removedBinding.bindingID))
            XCTAssertEqual(try store.workloadProfiles.listProfiles(), newerProfiles)
            XCTAssertEqual(try store.withConnection(readOnly: true) { try $0.query("SELECT revoked_at FROM plugin_grants WHERE package_digest=?", bindings: [.text(pluginDigest)]) }, [["2026-08-02T20:01:00Z"]])
            XCTAssertThrowsError(try store.withConnection { try $0.run("DELETE FROM plugin_provenance WHERE package_digest=?", bindings: [.text(pluginDigest)]) })
            XCTAssertNotNil(try store.controlIdentities.loadSession(oldA.sessionID)?.revokedAt)
            XCTAssertNotNil(try store.controlIdentities.loadSession(oldB.sessionID)?.revokedAt)
            XCTAssertThrowsError(try store.controlIdentities.validateActiveSession(oldA.sessionID,
                daemonGeneration: 1, at: "2026-08-02T20:04:00Z"))
            XCTAssertThrowsError(try store.controlIdentities.validateActiveSession(oldB.sessionID,
                daemonGeneration: 1, at: "2026-08-02T20:04:00Z"))
            XCTAssertThrowsError(try store.controlIdentities.persistSession(oldA))
            XCTAssertThrowsError(try store.controlIdentities.persistSession(oldB))
            let restoredSession = ControlSessionRecord(sessionID: "new-A-session", subjectID: "owner", daemonGeneration: 2,
                serverNonceSHA256: String(repeating: "f", count: 64), socketDevice: 1, socketInode: 2,
                effectiveUID: 501, effectiveGID: 20, pid: 123, pidVersion: 1, auditSessionID: 1,
                codeDirectoryHash: codeA.codeDirectoryHash, createdAt: "2026-08-02T20:03:00Z",
                expiresAt: "2026-08-02T22:00:00Z", updatedAt: "2026-08-02T20:03:00Z")
            try checked("fresh A session") { try store.controlIdentities.persistSession(restoredSession) }
            _ = try store.controlIdentities.validateActiveSession(restoredSession.sessionID,
                daemonGeneration: 2, at: "2026-08-02T20:04:00Z")
            let restoredOwner = try XCTUnwrap(store.controlIdentities.loadIdentity("owner"))
            XCTAssertNil(restoredOwner.credentialID)
            XCTAssertNil(restoredOwner.revokedAt)
            let revokedPeer = try XCTUnwrap(store.controlIdentities.loadIdentity("proof-peer"))
            XCTAssertEqual(revokedPeer.credentialID, "credential-B")
            XCTAssertNotNil(revokedPeer.revokedAt)
            let adapter = try SQLiteControlIdentitySecurityAdapter(store: store, sessionLifetime: 600)
            let denied = try adapter.resolve(userID: 501, codeIdentity: proofCode)
            XCTAssertTrue(denied.isRevoked)
            XCTAssertEqual(denied.credential?.identifier, "credential-B")
            for oldCredential in ["credential-A", "credential-B"] {
                XCTAssertThrowsError(try store.controlIdentities.rotateCredential(subjectID: "proof-peer",
                    expectedGeneration: revokedPeer.generation, credentialID: oldCredential,
                    credentialPublicKeyBase64: credentialKey, credentialExpiresAt: nil, updatedAt: "2026-09-13T20:00:00Z"))
            }
            let freshCode = CodeIdentity(teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.fresh-proof-peer",
                codeDirectoryHash: String(repeating: "d", count: 64), validationMode: .installedRequirement)
            for oldCredential in ["credential-A", "credential-B"] {
                let replay = ControlPeerIdentityRecord(subjectID: "replay-" + oldCredential, userID: 501, codeIdentity: freshCode,
                    credentialID: oldCredential, credentialPublicKeyBase64: credentialKey, declaredBySubjectID: "owner",
                    declaredAt: "2026-09-13T20:00:00Z", updatedAt: "2026-09-13T20:00:00Z")
                XCTAssertThrowsError(try store.controlIdentities.declare(replay))
            }
            let freshCredentialKey = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
            let fresh = ControlPeerIdentityRecord(subjectID: "fresh-proof-peer", userID: 501, codeIdentity: freshCode,
                credentialID: "credential-fresh", credentialPublicKeyBase64: freshCredentialKey,
                declaredBySubjectID: "owner", declaredAt: "2026-09-13T20:00:00Z", updatedAt: "2026-09-13T20:00:00Z")
            try checked("fresh owner peer issuance") { try store.controlIdentities.declare(fresh) }
            let accepted = try adapter.resolve(userID: 501, codeIdentity: freshCode)
            XCTAssertFalse(accepted.isRevoked)
            XCTAssertEqual(accepted.credential?.identifier, "credential-fresh")
            _ = try trail.append(input("release-A-restored"))
            XCTAssertEqual(trail.verify().health, .healthy)
            XCTAssertEqual(trail.verify().recordCount, 3)
        }
    }

    func testAuditContinuousRollbackPreservesIndependentNativeHashRevocation() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, directory in
            let keys = InMemoryAuditSigningKeyStore()
            let codeA = CodeIdentity(teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.client",
                codeDirectoryHash: String(repeating: "a", count: 64), validationMode: .installedRequirement)
            let codeB = CodeIdentity(teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.client",
                codeDirectoryHash: String(repeating: "b", count: 64), validationMode: .installedRequirement)
            let owner = ControlPeerIdentityRecord(subjectID: "owner", userID: 501, codeIdentity: codeA,
                declaredBySubjectID: "owner", declaredAt: "2026-08-02T20:00:00Z", updatedAt: "2026-08-02T20:00:00Z")
            try store.controlIdentities.bootstrap(owner)
            // Another active subject keeps A from being automatically retired during the owner rotation.
            try store.controlIdentities.declare(ControlPeerIdentityRecord(subjectID: "other-user", userID: 502,
                codeIdentity: codeA, declaredBySubjectID: "owner", declaredAt: "2026-08-02T20:00:00Z",
                updatedAt: "2026-08-02T20:00:00Z"))
            let rollback = directory.appendingPathComponent("rollback")
            try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let service = StateUpgradeService(store: store)
            let snapshot = try service.createVerifiedSnapshot(at: rollback.appendingPathComponent("state.sqlite").path)
            _ = try store.controlIdentities.rotateInstalledCodeIdentity(subjectID: "owner", expectedGeneration: 1,
                replacement: codeB, updatedAt: "2026-08-02T20:01:00Z")
            try store.controlIdentities.revoke(ControlIdentityRevocationRecord(revocationID: "manual-A-hash-revocation",
                targetKind: .codeHash, targetIdentifier: codeA.codeDirectoryHash, reason: "independent security revocation",
                actorSubjectID: "owner", revokedAt: "2026-08-02T20:02:00Z"))
            let before = try service.verifiedRevision()
            XCTAssertThrowsError(try service.restoreVerifiedSnapshotPreservingAudit(snapshot,
                operationID: "00000000-0000-0000-0000-000000000009", keyStore: keys,
                approvedInstalledCodeIdentities: [codeA], expectedCurrentInstalledCodeIdentities: [codeB]))
            XCTAssertEqual(try service.verifiedRevision(), before)
            XCTAssertEqual(try store.controlIdentities.loadIdentity("owner")?.codeIdentity, codeB)
            XCTAssertEqual(TamperEvidentAuditTrail(store: store, keyStore: keys).verify().health, .healthy)
        }
    }

    func testAuditContinuousRollbackRefusesTamperedCurrentChainBeforeStateReplacement() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, directory in
            let keys = InMemoryAuditSigningKeyStore()
            let trail = TamperEvidentAuditTrail(store: store, keyStore: keys)
            _ = try trail.append(AuditAppendInput(subjectID: "owner", requestID: "A", action: .authentication,
                outcome: "accepted", reasonCode: "accepted", payloadDigest: "sha256:" + String(repeating: "a", count: 64)))
            let snapshotDirectory = directory.appendingPathComponent("rollback")
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let service = StateUpgradeService(store: store)
            let snapshot = try service.createVerifiedSnapshot(at: snapshotDirectory.appendingPathComponent("state.sqlite").path)
            try store.withConnection { try $0.run("UPDATE audit_records SET reason_code='changed'") }
            let before = try service.verifiedRevision()
            let head = try keys.loadHead()
            XCTAssertThrowsError(try service.restoreVerifiedSnapshotPreservingAudit(snapshot,
                operationID: "00000000-0000-0000-0000-000000000008", keyStore: keys))
            XCTAssertEqual(try service.verifiedRevision(), before)
            XCTAssertEqual(try keys.loadHead(), head)
            XCTAssertEqual(trail.verify().health, .tampered)
        }
    }

    func testSchemaV16MigratesRestartBudgetsToV17WithSafeDefaults() throws {
        try withTemporaryStore(throughVersion: 16) { store, _ in
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO projects (id, name, manifest_hash, created_at, updated_at)
                    VALUES ('project-demo', 'demo', 'manifest', '2026-08-01T12:00:00Z', '2026-08-01T12:00:00Z')
                    """
                )
                try connection.run(
                    """
                    INSERT INTO restart_policy_state (
                        id, project_id, service_name, policy, status, attempt_count,
                        max_attempts, backoff_seconds, backoff_until, last_failure_at,
                        updated_at, metadata_json_redacted
                    ) VALUES (
                        'restart-api', 'project-demo', 'api', 'onFailure', 'backingOff',
                        1, 3, 60, '2026-08-01T12:01:00Z', '2026-08-01T12:00:00Z',
                        '2026-08-01T12:00:00Z', '{}'
                    )
                    """
                )
            }

            try MigrationRunner().apply(to: store, throughVersion: 17)
            XCTAssertEqual(try store.schemaVersion(), 17)
            try store.withConnection(createIfNeeded: false, readOnly: true) { connection in
                let row = try XCTUnwrap(
                    connection.query(
                        """
                        SELECT reason_class, window_started_at, window_seconds,
                               project_max_attempts, release_generation, policy_sha256
                        FROM restart_policy_state WHERE id = 'restart-api'
                        """
                    ).first)
                XCTAssertEqual(
                    row.compactMap { $0 },
                    [
                        "unknown", "2026-08-01T12:00:00Z", "300", "10", "0",
                        String(repeating: "0", count: 64),
                    ]
                )
                XCTAssertEqual(
                    try connection.query("SELECT id FROM restart_attempt_history"),
                    []
                )
            }
            try store.migrate()
            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            XCTAssertEqual(try store.restartAttempts.loadProject("project-demo"), [])
        }
    }

    func testSchemaV13MigratesAdditivelyToV14ContentCacheState()
        throws
    {
        try withTemporaryStore(throughVersion: 13) { store, _ in
            try store.withConnection { connection in
                try connection.run(
                    """
                    INSERT INTO oci_referrer_cache_objects (
                        digest, media_type, size_bytes, object_kind,
                        payload_base64, payload_sha256, children_json,
                        created_at, last_accessed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(
                            "sha256:6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"
                        ),
                        .text("application/octet-stream"),
                        .int(1), .text("blob"),
                        .text(Data([0]).base64EncodedString()),
                        .text(
                            "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"
                        ),
                        .text("[]"),
                        .text("2026-07-25T12:00:00Z"),
                        .text("2026-07-25T12:01:00Z")
                    ]
                )
            }

            try store.migrate()

            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            XCTAssertEqual(
                try store.contentCache.listContent(),
                [
                    ContentCacheRecord(
                        providerScope: "oci-referrer-cache",
                        digest:
                            "sha256:6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
                        kind: .ociCacheObject,
                        sizeBytes: 1,
                        createdAt: "2026-07-25T12:00:00Z",
                        observedAt: "2026-07-25T12:01:00Z",
                        lastUsedAt: "2026-07-25T12:01:00Z"
                    )
                ]
            )
            let report = StateIntegrityService(store: store).inspect()
            XCTAssertNotEqual(
                report.health,
                .unrecoverable,
                String(describing: report.checks)
            )
        }
    }

    func testSchemaV10MigratesToV11ImageSBOMStateWithoutGaps()
        throws
    {
        try withTemporaryStore(throughVersion: 10) { store, _ in
            XCTAssertEqual(try store.schemaVersion(), 10)

            try store.migrate()

            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            let evidence = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                let versions = try connection.query(
                    """
                    SELECT version
                    FROM schema_migrations
                    ORDER BY version
                    """
                ).compactMap { $0.first ?? nil }.compactMap(Int.init)
                let tables = Set(
                    try connection.query(
                        """
                        SELECT name
                        FROM sqlite_master
                        WHERE type = 'table'
                          AND name LIKE 'image_sbom%'
                        ORDER BY name
                        """
                    ).compactMap { $0.first ?? nil }
                )
                return (versions, tables)
            }
            XCTAssertEqual(
                evidence.0,
                Array(1...HostwrightContractVersions.stateSchema)
            )
            XCTAssertEqual(evidence.1, Set(["image_sbom_records"]))
        }
    }

    func testSchemaV8MigratesThroughV11ReferrerStateWithoutGaps()
        throws
    {
        try withTemporaryStore(throughVersion: 8) { store, _ in
            XCTAssertEqual(try store.schemaVersion(), 8)

            try store.migrate()

            XCTAssertEqual(
                try store.schemaVersion(),
                HostwrightContractVersions.stateSchema
            )
            let evidence = try store.withConnection(
                createIfNeeded: false,
                readOnly: true
            ) { connection in
                let versions = try connection.query(
                    """
                    SELECT version
                    FROM schema_migrations
                    ORDER BY version
                    """
                ).compactMap { $0.first ?? nil }.compactMap(Int.init)
                let tables = Set(
                    try connection.query(
                        """
                        SELECT name
                        FROM sqlite_master
                        WHERE type = 'table'
                          AND name LIKE 'oci_referrer%'
                        ORDER BY name
                        """
                    ).compactMap { $0.first ?? nil }
                )
                return (versions, tables)
            }
            XCTAssertEqual(
                evidence.0,
                Array(1...HostwrightContractVersions.stateSchema)
            )
            XCTAssertEqual(evidence.1, Set([
                "oci_referrer_cache_objects",
                "oci_referrer_discoveries",
                "oci_referrer_graph_objects",
                "oci_referrer_publications",
                "oci_referrer_retention_leases",
                "oci_referrers"
            ]))
        }
    }

    func testExclusiveLifecycleFenceRejectsConcurrentWriterAndAllowsNestedStateWork() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let finished = expectation(description: "concurrent state writer refused")
            let outcome = Mutex<String?>(nil)

            try StateUpgradeService(store: store).withExclusiveLifecycleFence {
                XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try store.migrate()
                        outcome.withLock { $0 = "unexpected-success" }
                    } catch {
                        outcome.withLock { $0 = String(describing: error) }
                    }
                    finished.fulfill()
                }
                wait(for: [finished], timeout: 2)
            }

            let result = try XCTUnwrap(outcome.withLock { $0 })
            XCTAssertNotEqual(result, "unexpected-success")
            XCTAssertTrue(result.contains("state-access fence"), result)
            XCTAssertNoThrow(try store.migrate())
        }
    }

    func testSynchronousExclusiveLifecycleFenceAuthorityPropagatesToInheritingTask() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let outcome = TaskOutcome()

            try StateUpgradeService(store: store).withExclusiveLifecycleFence {
                Task { [store, outcome] in
                    do {
                        let version = try store.schemaVersion()
                        outcome.record(
                            version == MigrationRunner.latestSchemaVersion
                                ? "success" : "unexpected-schema-version"
                        )
                    } catch {
                        outcome.record(String(describing: error))
                    }
                    outcome.finish()
                }
                XCTAssertEqual(outcome.wait(timeout: .now() + 2), .success)
            }

            XCTAssertEqual(outcome.value, "success")
        }
    }

    func testInheritedLifecycleFenceAuthorityIsRevokedWhenTheFenceReturns() async throws {
        try await withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            try store.configuration.prepareStateAccessFoundation()
            let lockPath = try store.configuration.maintenancePaths().accessLockPath

            let escaped = try StateUpgradeService(store: store).withExclusiveLifecycleFence {
                Task { [store] in
                    try? await Task.sleep(for: .milliseconds(100))
                    do {
                        _ = try store.schemaVersion()
                        return "unexpected-success"
                    } catch {
                        return String(describing: error)
                    }
                }
            }

            let descriptor = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let outcome = await escaped.value
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)

            XCTAssertNotEqual(outcome, "unexpected-success")
            XCTAssertTrue(outcome.contains("state-access fence"), outcome)
        }
    }

    func testAsyncLifecycleFenceAllowsNestedAccessAcrossAwaitAndExcludesCompetingAccessor()
        async throws
    {
        try await withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            let service = StateUpgradeService(store: store)

            try await service.withExclusiveLifecycleFence {
                try await Task.sleep(for: .milliseconds(10))
                XCTAssertEqual(
                    try store.schemaVersion(),
                    MigrationRunner.latestSchemaVersion
                )

                let competing = Task.detached { () -> String in
                    do {
                        try store.migrate()
                        return "unexpected-success"
                    } catch {
                        return String(describing: error)
                    }
                }
                let outcome = await competing.value
                XCTAssertNotEqual(outcome, "unexpected-success")
                XCTAssertTrue(outcome.contains("state-access fence"), outcome)
            }

            XCTAssertNoThrow(try store.migrate())
        }
    }

    func testSerializedLifecycleMutationDoesNotBlockOrdinarySharedStateAccess() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let readerFinished = expectation(description: "ordinary state reader completes")
            let readerOutcome = Mutex<String?>(nil)

            try StateUpgradeService(store: store).withSerializedLifecycleMutation {
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let version = try store.schemaVersion()
                        readerOutcome.withLock {
                            $0 = version == MigrationRunner.latestSchemaVersion
                                ? "success" : "unexpected-schema-version"
                        }
                    } catch {
                        readerOutcome.withLock { $0 = String(describing: error) }
                    }
                    readerFinished.fulfill()
                }
                wait(for: [readerFinished], timeout: 2)
            }

            XCTAssertEqual(readerOutcome.withLock { $0 }, "success")
        }
    }

    func testSerializedLifecycleMutationsFailClosedAtTheirWaitBound() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let service = StateUpgradeService(store: store)
            let enteredFirstMutation = DispatchSemaphore(value: 0)
            let releaseFirstMutation = DispatchSemaphore(value: 0)
            let firstOutcome = TaskOutcome()

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try service.withSerializedLifecycleMutation(lockWaitMilliseconds: 1_000) {
                        enteredFirstMutation.signal()
                        guard releaseFirstMutation.wait(timeout: .now() + 2) == .success else {
                            firstOutcome.record("release-timeout")
                            return
                        }
                    }
                    if firstOutcome.value == nil {
                        firstOutcome.record("success")
                    }
                } catch {
                    firstOutcome.record(String(describing: error))
                }
                firstOutcome.finish()
            }

            XCTAssertEqual(enteredFirstMutation.wait(timeout: .now() + 2), .success)
            XCTAssertThrowsError(
                try service.withSerializedLifecycleMutation(lockWaitMilliseconds: 50) {}
            ) { error in
                guard case let StateStoreError.databaseLocked(_, message) = error else {
                    return XCTFail("Expected databaseLocked, received \(error).")
                }
                XCTAssertTrue(message.contains("lifecycle-mutation fence"), message)
            }

            releaseFirstMutation.signal()
            XCTAssertEqual(firstOutcome.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(firstOutcome.value, "success")
        }
    }

    func testEscapedInheritedSerializedLifecycleMutationAuthorityIsRevoked()
        async throws
    {
        try await withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            let service = StateUpgradeService(store: store)
            let permitEscapedAttempt = LifecycleMutationGate()
            let holderEntered = LifecycleMutationGate()
            let releaseHolder = LifecycleMutationGate()

            let escaped = try await service.withSerializedLifecycleMutation {
                await Task.yield()
                return Task { [service, permitEscapedAttempt] in
                    await permitEscapedAttempt.wait()
                    do {
                        return try await service.withSerializedLifecycleMutation(
                            lockWaitMilliseconds: 50
                        ) {
                            await Task.yield()
                            return "unexpected-success"
                        }
                    } catch {
                        return String(describing: error)
                    }
                }
            }

            let holder = Task { () -> String in
                do {
                    return try await service.withSerializedLifecycleMutation(
                        lockWaitMilliseconds: 1_000
                    ) {
                        await holderEntered.release()
                        await releaseHolder.wait()
                        return "holder-success"
                    }
                } catch {
                    return String(describing: error)
                }
            }
            await holderEntered.wait()
            await permitEscapedAttempt.release()

            let escapedOutcome = await escaped.value
            XCTAssertNotEqual(escapedOutcome, "unexpected-success")
            XCTAssertTrue(escapedOutcome.contains("lifecycle-mutation fence"), escapedOutcome)

            await releaseHolder.release()
            let holderOutcome = await holder.value
            XCTAssertEqual(holderOutcome, "holder-success")
        }
    }

    func testAsyncExclusiveLifecycleFenceWaitsBehindMutationAndIsNestedReentrant()
        async throws
    {
        try await withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            let service = StateUpgradeService(store: store)
            let mutationEntered = DispatchSemaphore(value: 0)
            let releaseMutation = LifecycleMutationGate()
            let state = LifecycleMutationTestState()

            let mutation = Task { () throws -> Int in
                try await service.withSerializedLifecycleMutation {
                    state.setMutationActive(true)
                    defer { state.setMutationActive(false) }
                    mutationEntered.signal()
                    let version = try await service.withExclusiveLifecycleFence {
                        try await Task.sleep(for: .milliseconds(10))
                        return try store.schemaVersion()
                    }
                    await releaseMutation.wait()
                    return version
                }
            }

            XCTAssertEqual(mutationEntered.wait(timeout: .now() + 2), .success)
            let delayedRelease = Task.detached {
                try? await Task.sleep(for: .milliseconds(100))
                await releaseMutation.release()
            }
            try await service.withExclusiveLifecycleFence(lockWaitMilliseconds: 1_000) {
                await Task.yield()
                state.recordExclusiveEntry()
            }
            await delayedRelease.value

            switch await mutation.result {
            case .success(let version):
                XCTAssertEqual(version, MigrationRunner.latestSchemaVersion)
            case .failure(let error):
                XCTFail("Nested lifecycle fence failed: \(error)")
            }
            XCTAssertFalse(state.exclusiveEnteredWhileMutationActive)
        }
    }

    func testBoundedStateAccessWaitPropagatesAcrossAwaitWithoutBypassingTheFence()
        async throws
    {
        try await withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            try store.configuration.prepareStateAccessFoundation()
            let lockPath = try store.configuration.maintenancePaths().accessLockPath
            let descriptor = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let release = Task.detached {
                try? await Task.sleep(for: .milliseconds(400))
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }

            let version = try await StateUpgradeService(store: store)
                .withBoundedStateAccessWait(lockWaitMilliseconds: 1_000) {
                    try await StateUpgradeService(store: store)
                        .withBoundedStateAccessWait(lockWaitMilliseconds: 100) {
                            try await Task.sleep(for: .milliseconds(10))
                            return try store.schemaVersion()
                        }
                }
            await release.value
            XCTAssertEqual(version, MigrationRunner.latestSchemaVersion)
        }
    }

    func testBoundedStateAccessWaitRejectsUnboundedWaits() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) {
            store, _ in
            for timeout in [0, 30_001] {
                do {
                    try StateUpgradeService(store: store)
                        .withBoundedStateAccessWait(lockWaitMilliseconds: timeout) {}
                    XCTFail("Expected invalidRecord for \(timeout) milliseconds.")
                } catch {
                    guard case StateStoreError.invalidRecord = error else {
                        return XCTFail("Expected invalidRecord, received \(error).")
                    }
                }
            }
        }
    }

    func testExclusiveLifecycleFenceSupportsBoundedControlPlaneWait() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            try store.configuration.prepareStateAccessFoundation()
            let lockPath = try store.configuration.maintenancePaths().accessLockPath
            let descriptor = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let released = expectation(description: "competing writer released")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
                released.fulfill()
            }

            XCTAssertNoThrow(
                try StateUpgradeService(store: store).withExclusiveLifecycleFence(
                    lockWaitMilliseconds: 1_000
                ) {
                    XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
                }
            )
            wait(for: [released], timeout: 1)
        }
    }

    func testExclusiveLifecycleFenceRejectsUnboundedWaits() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            for timeout in [0, 30_001] {
                XCTAssertThrowsError(
                    try StateUpgradeService(store: store).withExclusiveLifecycleFence(
                        lockWaitMilliseconds: timeout
                    ) {}
                ) { error in
                    guard case StateStoreError.invalidRecord = error else {
                        return XCTFail("Expected invalidRecord, received \(error).")
                    }
                }
            }
        }
    }

    func testVerifiedStateRemovalDeletesOnlyTheManagedSQLiteFileSet() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let result = try StateDatabaseRemovalService(store: store).removeVerifiedDatabase()

            XCTAssertEqual(result.kind, "stateDatabaseRemovalResult")
            XCTAssertEqual(result.databasePath, store.path)
            XCTAssertTrue(result.removedPaths.contains(store.path))
            XCTAssertEqual(result.removedPaths, result.removedPaths.sorted())
            for path in result.removedPaths {
                XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        }
    }

    func testVerifiedStateRemovalRefusesForeignSQLiteWithoutDeletingIt() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, _ in
            let foreignID = 0x0BAD_F00D
            let connection = try SQLiteConnection(
                path: store.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try connection.execute("PRAGMA application_id = \(foreignID)")
            try connection.close()
            let before = try StateMaintenanceFileSupport.fingerprint(store.path)

            XCTAssertThrowsError(
                try StateDatabaseRemovalService(store: store).removeVerifiedDatabase()
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
            XCTAssertEqual(try StateMaintenanceFileSupport.fingerprint(store.path), before)
        }
    }

    func testVerifiedStandaloneWALSnapshotInspectionDoesNotCreateSidecars() throws {
        try withTemporaryStore(throughVersion: MigrationRunner.latestSchemaVersion) { store, directory in
            let rollback = directory.appendingPathComponent("rollback")
            try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let service = StateUpgradeService(store: store)
            let original = try service.createVerifiedSnapshot(at: rollback.appendingPathComponent("state.sqlite").path)
            let connection = try SQLiteConnection(path: original.snapshotPath, createIfNeeded: false,
                profile: .authoritativeState)
            _ = try connection.query("PRAGMA wal_checkpoint(TRUNCATE)")
            try connection.close()
            for suffix in ["-wal", "-shm"] where StateMaintenanceFileSupport.exists(original.snapshotPath + suffix) {
                try StateMaintenanceFileSupport.unlinkSensitiveFile(original.snapshotPath + suffix)
            }
            let fingerprint = try StateMaintenanceFileSupport.fingerprint(original.snapshotPath)
            let snapshot = StateUpgradeSnapshot(databasePath: store.path, snapshotPath: original.snapshotPath,
                databaseSHA256: fingerprint.sha256, databaseBytes: fingerprint.bytes,
                stateSchemaVersion: original.stateSchemaVersion)
            for _ in 0..<2 {
                try service.verify(snapshot)
                for suffix in ["-journal", "-wal", "-shm"] {
                    XCTAssertFalse(StateMaintenanceFileSupport.exists(snapshot.snapshotPath + suffix))
                }
                XCTAssertEqual(try StateMaintenanceFileSupport.fingerprint(snapshot.snapshotPath), fingerprint)
            }
        }
    }

    func testVerifiedV16SnapshotMigratesAndRestoresExactPriorSchema() throws {
        try withTemporaryStore(throughVersion: 16) { store, directory in
            let snapshotURL = directory.appendingPathComponent("rollback/state.sqlite")
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let service = StateUpgradeService(store: store)

            let snapshot = try service.createVerifiedSnapshot(at: snapshotURL.path)
            XCTAssertEqual(snapshot.kind, "stateUpgradeSnapshot")
            XCTAssertEqual(snapshot.stateSchemaVersion, 16)
            XCTAssertEqual(snapshot.databaseSHA256.count, 64)
            XCTAssertGreaterThan(snapshot.databaseBytes, 0)
            XCTAssertEqual(permissions(snapshotURL.path), 0o600)
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-wal"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path + "-shm"))

            let migration = try service.migrateToLatest()
            XCTAssertEqual(migration.fromSchemaVersion, 16)
            XCTAssertEqual(migration.toSchemaVersion, MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)

            let operationID = "00000000-0000-0000-0000-000000000001"
            let restoreStage = URL(
                fileURLWithPath: (store.path as NSString).deletingLastPathComponent,
                isDirectory: true
            ).appendingPathComponent(
                ".hostwright-state-upgrade-restore-\(operationID).sqlite"
            )

            XCTAssertThrowsError(
                try StateUpgradeService(
                    store: store,
                    testInterruption: .afterRestorePublishedAndVerified
                ).restoreVerifiedSnapshot(snapshot, operationID: operationID)
            ) { error in
                XCTAssertEqual(
                    error as? StateUpgradeTestInterruption,
                    .afterRestorePublishedAndVerified
                )
            }
            XCTAssertEqual(try store.schemaVersion(), 16)
            XCTAssertEqual(
                try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
                snapshot.databaseSHA256
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: restoreStage.path))

            let restoredVersion = try service.restoreVerifiedSnapshot(
                snapshot,
                operationID: operationID
            )
            XCTAssertEqual(restoredVersion, 16)
            XCTAssertEqual(try store.schemaVersion(), 16)
            XCTAssertEqual(
                try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
                snapshot.databaseSHA256
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: restoreStage.path))

            let secondMigration = try service.migrateToLatest()
            XCTAssertEqual(secondMigration.fromSchemaVersion, 16)
            XCTAssertEqual(secondMigration.toSchemaVersion, MigrationRunner.latestSchemaVersion)
        }
    }

    func testTamperedUpgradeSnapshotCannotReplaceCurrentState() throws {
        try withTemporaryStore(throughVersion: 6) { store, directory in
            let rollback = directory.appendingPathComponent("rollback", isDirectory: true)
            try FileManager.default.createDirectory(
                at: rollback,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let service = StateUpgradeService(store: store)
            let snapshot = try service.createVerifiedSnapshot(
                at: rollback.appendingPathComponent("state.sqlite").path
            )
            _ = try service.migrateToLatest()
            let currentDigest = try StateMaintenanceFileSupport.fingerprint(store.path).sha256

            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: snapshot.snapshotPath))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("tamper".utf8))
            try handle.close()

            XCTAssertThrowsError(
                try service.restoreVerifiedSnapshot(
                    snapshot,
                    operationID: "00000000-0000-0000-0000-000000000002"
                )
            )
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
            XCTAssertEqual(try StateMaintenanceFileSupport.fingerprint(store.path).sha256, currentDigest)
        }
    }

    func testV17SnapshotMigratesToLatestAndRestoresExactV17() throws {
        try withTemporaryStore(throughVersion: 17) { store, directory in
            let rollback = directory.appendingPathComponent("rollback", isDirectory: true)
            try FileManager.default.createDirectory(
                at: rollback,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let service = StateUpgradeService(store: store)
            let snapshot = try service.createVerifiedSnapshot(
                at: rollback.appendingPathComponent("state.sqlite").path
            )
            XCTAssertEqual(snapshot.stateSchemaVersion, 17)
            XCTAssertEqual(
                try service.migrateToLatest().toSchemaVersion,
                MigrationRunner.latestSchemaVersion
            )
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)

            XCTAssertEqual(
                try service.restoreVerifiedSnapshot(
                    snapshot,
                    operationID: "00000000-0000-0000-0000-000000000018"
                ),
                17
            )
            XCTAssertEqual(try store.schemaVersion(), 17)
            XCTAssertEqual(
                try StateMaintenanceFileSupport.fingerprint(store.path).sha256,
                snapshot.databaseSHA256
            )
        }
    }

    func testV17MigrationCreatesVerifiedRollbackPackageAndReachesLatestSchema() throws {
        try withTemporaryStore(throughVersion: 17) { store, directory in
            let service = StateUpgradeService(store: store)

            let result = try service.migrateToLatestWithVerifiedBackup()

            XCTAssertEqual(result.kind, "stateUpgradePreparedMigrationResult")
            XCTAssertEqual(result.migration.fromSchemaVersion, 17)
            XCTAssertEqual(
                result.migration.toSchemaVersion,
                MigrationRunner.latestSchemaVersion
            )
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)

            let snapshot = try XCTUnwrap(result.rollbackSnapshot)
            XCTAssertEqual(snapshot.databasePath, store.path)
            XCTAssertEqual(snapshot.stateSchemaVersion, 17)
            XCTAssertGreaterThan(snapshot.databaseBytes, 0)
            XCTAssertEqual(snapshot.databaseSHA256.count, 64)
            XCTAssertNoThrow(try service.verify(snapshot))

            let rollbackDirectory = URL(fileURLWithPath: snapshot.snapshotPath)
                .deletingLastPathComponent()
            let rollbackRoot = directory.appendingPathComponent(
                ".hostwright-state-upgrades",
                isDirectory: true
            )
            let manifestURL = rollbackDirectory.appendingPathComponent("snapshot-v1.json")
            XCTAssertEqual(rollbackDirectory.deletingLastPathComponent(), rollbackRoot)
            XCTAssertEqual(permissions(rollbackRoot.path), 0o700)
            XCTAssertEqual(permissions(rollbackDirectory.path), 0o700)
            XCTAssertEqual(permissions(snapshot.snapshotPath), 0o600)
            XCTAssertEqual(permissions(manifestURL.path), 0o600)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    StateUpgradeSnapshot.self,
                    from: Data(contentsOf: manifestURL)
                ),
                snapshot
            )
        }
    }

    func testAbsentDatabaseInitializesLatestWithoutRollbackSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        let rollbackRoot = directory.appendingPathComponent(
            ".hostwright-state-upgrades",
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackRoot.path))

        let result = try StateUpgradeService(store: store).migrateToLatestWithVerifiedBackup()

        XCTAssertEqual(result.kind, "stateUpgradePreparedMigrationResult")
        XCTAssertEqual(
            result.migration.fromSchemaVersion,
            MigrationRunner.latestSchemaVersion
        )
        XCTAssertEqual(
            result.migration.toSchemaVersion,
            MigrationRunner.latestSchemaVersion
        )
        XCTAssertNil(result.rollbackSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackRoot.path))
    }

    private func withTemporaryStore(
        throughVersion: Int,
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try MigrationRunner().apply(to: store, throughVersion: throughVersion)
        try body(store, directory)
    }

    private func withTemporaryStore(
        throughVersion: Int,
        _ body: (SQLiteStateStore, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-state-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try MigrationRunner().apply(to: store, throughVersion: throughVersion)
        try await body(store, directory)
    }

    private func permissions(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class TaskOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var storedValue: String?

    func record(_ value: String) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func finish() {
        completion.signal()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        completion.wait(timeout: timeout)
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private final class LifecycleMutationTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var mutationActive = false
    private var exclusiveEntrySawActiveMutation = false

    func setMutationActive(_ active: Bool) {
        lock.lock()
        mutationActive = active
        lock.unlock()
    }

    func recordExclusiveEntry() {
        lock.lock()
        exclusiveEntrySawActiveMutation = mutationActive
        lock.unlock()
    }

    var exclusiveEnteredWhileMutationActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exclusiveEntrySawActiveMutation
    }
}

private actor LifecycleMutationGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

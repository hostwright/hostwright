import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightState
import XCTest

@testable import HostwrightCLI

final class ControlIdentityBootstrapTests: XCTestCase {
    func testBootstrapDeclaresFirstIdentityAndAcceptsInstalledRequirementRotation() throws {
        try withStore { store in
            let initial = installedIdentity(hash: "a")
            try HostwrightControlIdentityBootstrap.bootstrap(
                store: store,
                userID: UInt32(geteuid()),
                codeIdentity: initial,
                timestamp: "2026-08-02T20:00:00Z"
            )
            let records = try store.controlIdentities.listIdentities()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].codeIdentity, initial)

            XCTAssertNoThrow(
                try HostwrightControlIdentityBootstrap.bootstrap(
                    store: store,
                    userID: UInt32(geteuid()),
                    codeIdentity: installedIdentity(hash: "b"),
                    timestamp: "2026-08-02T20:01:00Z"
                )
            )
            XCTAssertEqual(try store.controlIdentities.listIdentities().count, 1)
        }
    }

    func testBootstrapRefusesUndeclaredAdHocReplacement() throws {
        try withStore { store in
            try HostwrightControlIdentityBootstrap.bootstrap(
                store: store,
                userID: UInt32(geteuid()),
                codeIdentity: adHocIdentity(hash: "a"),
                timestamp: "2026-08-02T20:00:00Z"
            )
            XCTAssertThrowsError(
                try HostwrightControlIdentityBootstrap.bootstrap(
                    store: store,
                    userID: UInt32(geteuid()),
                    codeIdentity: adHocIdentity(hash: "b"),
                    timestamp: "2026-08-02T20:01:00Z"
                )
            )
        }
    }

    func testBootstrapAPIPairDeclaresInstallerAsOwnerAndPinsCompanionSeparately() throws {
        try withStore { store in
            let installer = adHocIdentity(hash: "a")
            let companion = adHocIdentity(hash: "b", signingIdentifier: "hostwright-control")
            try HostwrightControlIdentityBootstrap.bootstrap(
                store: store,
                userID: UInt32(geteuid()),
                codeIdentity: installer,
                companionIdentity: companion,
                timestamp: "2026-08-02T20:00:00Z"
            )

            let identities = try store.controlIdentities.listIdentities()
            XCTAssertEqual(identities.count, 2)
            let owner = try XCTUnwrap(identities.first(where: { $0.codeIdentity == installer }))
            let pinnedCompanion = try XCTUnwrap(
                identities.first(where: { $0.codeIdentity == companion })
            )
            XCTAssertEqual(pinnedCompanion.declaredBySubjectID, owner.subjectID)
            XCTAssertTrue(
                try store.rbac.listBindings().contains(where: {
                    $0.subjectID == owner.subjectID && $0.roleID == "owner"
                })
            )
            XCTAssertFalse(
                try store.rbac.listBindings().contains(where: {
                    $0.subjectID == pinnedCompanion.subjectID && $0.roleID == "owner"
                })
            )

            XCTAssertNoThrow(try HostwrightControlIdentityBootstrap.bootstrap(
                store: store,
                userID: UInt32(geteuid()),
                codeIdentity: installer,
                companionIdentity: companion,
                timestamp: "2026-08-02T20:01:00Z"
            ))
            XCTAssertThrowsError(try HostwrightControlIdentityBootstrap.bootstrap(
                store: store,
                userID: UInt32(geteuid()),
                codeIdentity: installer,
                companionIdentity: adHocIdentity(
                    hash: "c",
                    signingIdentifier: "hostwright-control"
                ),
                timestamp: "2026-08-02T20:02:00Z"
            ))
            XCTAssertEqual(try store.controlIdentities.listIdentities().count, 2)
        }
    }

    func testBootstrapAPIPairRejectsWrongCompanionIdentifierOrTrustDomain() throws {
        try withStore { store in
            XCTAssertThrowsError(try HostwrightControlIdentityBootstrap.bootstrap(
                store: store,
                userID: UInt32(geteuid()),
                codeIdentity: adHocIdentity(hash: "a"),
                companionIdentity: adHocIdentity(hash: "b", signingIdentifier: "hostwrightd"),
                timestamp: "2026-08-02T20:00:00Z"
            ))
            XCTAssertTrue(try store.controlIdentities.listIdentities().isEmpty)
        }
    }

    func testBootstrapAPIPairAcceptsExactSwiftPMAdHocIdentifierShapes() throws {
        try withStore { store in
            try HostwrightControlIdentityBootstrap.bootstrap(
                store: store,
                userID: UInt32(geteuid()),
                codeIdentity: adHocIdentity(
                    hash: "a",
                    signingIdentifier: "hostwright-" + String(repeating: "1", count: 40)
                ),
                companionIdentity: adHocIdentity(
                    hash: "b",
                    signingIdentifier: "hostwright-control-" + String(repeating: "2", count: 40)
                ),
                timestamp: "2026-08-02T20:00:00Z"
            )
            XCTAssertEqual(try store.controlIdentities.listIdentities().count, 2)
        }
    }

    private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-control-bootstrap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(store)
    }

    private func installedIdentity(hash: Character) -> CodeIdentity {
        CodeIdentity(
            teamIdentifier: ControlPeerTrustPolicy.installedTeamIdentifier,
            signingIdentifier: "hostwright",
            codeDirectoryHash: String(repeating: String(hash), count: 40),
            validationMode: .installedRequirement
        )
    }

    private func adHocIdentity(
        hash: Character,
        signingIdentifier: String = "hostwright"
    ) -> CodeIdentity {
        CodeIdentity(
            signingIdentifier: signingIdentifier,
            codeDirectoryHash: String(repeating: String(hash), count: 40),
            validationMode: .pinnedAdHoc
        )
    }
}

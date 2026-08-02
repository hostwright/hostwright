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

    private func adHocIdentity(hash: Character) -> CodeIdentity {
        CodeIdentity(
            signingIdentifier: "hostwright",
            codeDirectoryHash: String(repeating: String(hash), count: 40),
            validationMode: .pinnedAdHoc
        )
    }
}

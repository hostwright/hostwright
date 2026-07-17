import Foundation
@testable import HostwrightDistribution
import XCTest

final class DistributionPackageLifecycleTests: XCTestCase {
    func testQualificationVersionsMapMonotonicallyToApplePackageVersions() throws {
        XCTAssertEqual(
            try DistributionPackageVersion.make(from: "0.0.2-dev.3"),
            "0.0.2.3"
        )
        XCTAssertEqual(
            try DistributionPackageVersion.make(from: "0.0.2-dev.4"),
            "0.0.2.4"
        )
        XCTAssertEqual(
            DistributionPackageVersion.compare("0.0.2.3", "0.0.2.4"),
            .orderedAscending
        )
        XCTAssertThrowsError(
            try DistributionPackageVersion.make(from: "0.0.2-beta.1")
        )
        XCTAssertFalse(DistributionPackageVersion.isValid("0.0.2.01"))
    }

    func testPackageReceiptParserRequiresExactIdentifierVersionAndRootLocation() throws {
        let receipt: [String: Any] = [
            "pkgid": DistributionLayout.packageIdentifier,
            "pkg-version": "0.0.2.2",
            "install-location": "/",
            "volume": "/"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: receipt,
            format: .xml,
            options: 0
        )
        XCTAssertEqual(
            try DistributionPackageReceiptParser.parse(data),
            DistributionPackageReceipt(
                identifier: DistributionLayout.packageIdentifier,
                version: "0.0.2.2",
                installLocation: "/",
                volume: "/"
            )
        )

        for (key, value) in [
            ("pkgid", "dev.attacker.hostwright"),
            ("pkg-version", "0.0.2-dev.2"),
            ("install-location", "/tmp"),
            ("volume", "/Volumes/Other")
        ] {
            var tampered = receipt
            tampered[key] = value
            let tamperedData = try PropertyListSerialization.data(
                fromPropertyList: tampered,
                format: .xml,
                options: 0
            )
            XCTAssertThrowsError(
                try DistributionPackageReceiptParser.parse(tamperedData),
                "tampered receipt field \(key) must be rejected"
            )
        }
    }

    func testPackageOriginIsAdditiveAndBindsCurrentPayloadToNewestReceipt() throws {
        let manifest = makeInstallManifest(version: "0.0.2-dev.1")
        let origin = DistributionPackageOrigin(
            packageIdentifier: DistributionLayout.packageIdentifier,
            packageVersion: "0.0.2.1",
            mostRecentPackageReceiptVersion: "0.0.2.2"
        )
        let status = DistributionInstallationStatus(
            installationID: "11111111-1111-1111-1111-111111111111",
            generation: 3,
            prefix: "/usr/local",
            installedManifest: manifest,
            stateDatabasePath: nil,
            service: .notInstalled,
            rollbackOperationID: nil,
            packageOrigin: origin,
            updatedAt: "2026-07-15T12:00:00Z"
        )
        XCTAssertNoThrow(try status.validate())
        XCTAssertEqual(status.installationSource, .package)
        XCTAssertEqual(status.packageOrigin, origin)

        let encoded = try DistributionJSON.encode(status)
        let decoded = try JSONDecoder().decode(DistributionInstallationStatus.self, from: encoded)
        XCTAssertEqual(decoded, status)

        let legacy = DistributionInstallationStatus(
            installationID: "22222222-2222-2222-2222-222222222222",
            generation: 1,
            prefix: "/usr/local",
            installedManifest: manifest,
            stateDatabasePath: nil,
            service: .notInstalled,
            rollbackOperationID: nil,
            updatedAt: "2026-07-15T12:00:00Z"
        )
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertNil(legacy.installationSource)
        XCTAssertNil(legacy.packageOrigin)
    }

    func testPackageOriginRejectsInstalledPayloadVersionMismatch() throws {
        let status = DistributionInstallationStatus(
            installationID: "33333333-3333-3333-3333-333333333333",
            generation: 1,
            prefix: "/usr/local",
            installedManifest: makeInstallManifest(version: "0.0.2-dev.1"),
            stateDatabasePath: nil,
            service: .notInstalled,
            rollbackOperationID: nil,
            packageOrigin: DistributionPackageOrigin(
                packageIdentifier: DistributionLayout.packageIdentifier,
                packageVersion: "0.0.2.2",
                mostRecentPackageReceiptVersion: "0.0.2.2"
            ),
            updatedAt: "2026-07-15T12:00:00Z"
        )

        XCTAssertThrowsError(try status.validate()) { error in
            XCTAssertEqual(
                error as? DistributionError,
                .lifecycleFailed(
                    "installation status package version does not match installed manifest"
                )
            )
        }
    }

    func testPostinstallEntrypointUsesOnlyLockedPackageLifecycleArguments() {
        let script = DistributionPackageScripts.postinstall(
            packageVersion: "0.0.2.2",
            teamIdentifier: "A1B2C3D4E5"
        )
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\nset -eu\n"))
        XCTAssertTrue(script.contains("hostwright-dist' package-apply"))
        XCTAssertTrue(script.contains("--staged-root '/Library/Application Support/Hostwright/InstallerPayload'"))
        XCTAssertTrue(script.contains("--prefix '/usr/local'"))
        XCTAssertTrue(script.contains("--package-id 'dev.hostwright.cli'"))
        XCTAssertTrue(script.contains("--package-version '0.0.2.2'"))
        XCTAssertTrue(script.contains("--team-id 'A1B2C3D4E5'"))
        XCTAssertFalse(script.contains("TOKEN"))
        XCTAssertFalse(script.contains("PASSWORD"))
    }

    private func makeInstallManifest(version: String) -> DistributionInstallManifest {
        let commit = String(repeating: "a", count: 40)
        let artifact = DistributionArtifactManifest(
            artifactID: "hostwright-\(version)-macos-arm64-\(commit.prefix(12))",
            packageVersion: version,
            sourceCommit: commit,
            sourceDirty: false,
            architecture: "arm64",
            createdAt: "2026-07-15T12:00:00Z",
            files: DistributionLayout.payloadModes.keys.sorted().map { path in
                DistributionFileRecord(
                    path: path,
                    sha256: String(repeating: "b", count: 64),
                    sizeBytes: 1,
                    mode: DistributionLayout.payloadModes[path]!
                )
            }
        )
        return DistributionInstallManifest(artifact: artifact, createdDirectories: [])
    }
}

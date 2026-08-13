import XCTest
@testable import HostwrightManifest

final class RetentionManifestTests: XCTestCase {
    func testCompleteRetentionPolicyRoundTripsCanonically() throws {
        let source = manifest(retention: """
        retention:
          recoveryHorizon: 3600s
          maximumDatabaseBytes: 104857600
          targetDatabaseBytes: 52428800
          classes:
            operations: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
            observations: { maxAge: 7200s, maxRecords: 2000, minimumRecords: 20 }
            events: { maxAge: 86400s, maxRecords: 3000, minimumRecords: 30 }
            logs: { maxAge: 86400s, maxRecords: 4000, minimumRecords: 40 }
            metrics: { maxAge: 86400s, maxRecords: 5000, minimumRecords: 50 }
            traces: { maxAge: 86400s, maxRecords: 6000, minimumRecords: 60 }
            audits: { maxAge: 31536000s, maxRecords: 7000, minimumRecords: 70 }
            supportEvidence: { maxAge: 2592000s, maxRecords: 8000, minimumRecords: 80 }
            backups: { maxAge: 604800s, maxRecords: 9, minimumRecords: 2 }
            tombstones: { maxAge: 172800s, maxRecords: 10000, minimumRecords: 100 }
          holds:
            - id: incident-42
              class: audits
              selector: operation:1234
              reason: Preserve incident evidence
              expiresAt: "2026-09-01T00:00:00Z"
        """)

        let parsed = try ManifestValidator.validated(source)
        let retention = try XCTUnwrap(parsed.retention)
        XCTAssertEqual(retention.classes.count, 10)
        XCTAssertEqual(retention.holds.first?.retentionClass, .audits)
        XCTAssertEqual(retention.targetDatabaseBytes, 52_428_800)

        let canonical = try ManifestCanonicalEncoder.encode(parsed)
        XCTAssertEqual(try ManifestValidator.validated(canonical), parsed)
        XCTAssertTrue(canonical.contains("supportEvidence:"))
        XCTAssertTrue(canonical.contains("selector: \"operation:1234\""))
    }

    func testMissingRetentionPolicyPreservesLegacyBehavior() throws {
        let parsed = try ManifestValidator.validated(manifest(retention: ""))
        XCTAssertNil(parsed.retention)
        XCTAssertFalse(try ManifestCanonicalEncoder.encode(parsed).contains("retention:"))
    }

    func testRetentionRejectsMissingClassContradictoryBoundsAndUnsafeHold() {
        let source = manifest(retention: """
        retention:
          recoveryHorizon: 3600s
          maximumDatabaseBytes: 1048576
          targetDatabaseBytes: 2097152
          classes:
            operations: { maxAge: 60s, maxRecords: 1, minimumRecords: 2 }
          holds:
            - id: BAD_ID
              class: events
              selector: "../../secret"
              reason: " bad reason "
        """)
        XCTAssertThrowsError(try ManifestValidator.validated(source))
    }

    func testRetentionRejectsUnknownFieldsAndDuplicateHoldIDs() {
        var policy = completePolicy
        policy += """
          holds:
            - id: preserve
              class: events
              selector: "*"
              reason: First
            - id: preserve
              class: audits
              selector: "*"
              reason: Second
        """
        XCTAssertThrowsError(try ManifestValidator.validated(manifest(retention: policy)))

        let unknown = completePolicy.replacingOccurrences(
            of: "retention:",
            with: "retention:\n  unsafePrune: true"
        )
        XCTAssertThrowsError(try ManifestValidator.validated(manifest(retention: unknown)))
    }

    private var completePolicy: String {
        """
        retention:
          recoveryHorizon: 3600s
          maximumDatabaseBytes: 104857600
          targetDatabaseBytes: 52428800
          classes:
            operations: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
            observations: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
            events: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
            logs: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
            metrics: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
            traces: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
            audits: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
            supportEvidence: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
            backups: { maxAge: 86400s, maxRecords: 10, minimumRecords: 1 }
            tombstones: { maxAge: 86400s, maxRecords: 1000, minimumRecords: 10 }
        """
    }

    private func manifest(retention: String) -> String {
        """
        version: 2
        project: demo
        \(retention)
        services:
          api:
            image: local/api:latest
        """
    }
}

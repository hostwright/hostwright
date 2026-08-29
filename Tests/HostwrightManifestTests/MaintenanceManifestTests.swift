import XCTest
@testable import HostwrightManifest

final class MaintenanceManifestTests: XCTestCase {
    func testRecurringAndOneShotWindowsRoundTripCanonically() throws {
        let source = """
        version: 3
        project: demo
        maintenance:
          timezone: America/New_York
          maximumDeferral: 172800s
          windows:
            - id: weekly
              actions:
                - restart
                - create
              recurring:
                weekdays:
                  - sunday
                  - monday
                start: "02:30"
                duration: 3600s
            - id: release
              actions:
                - update
              oneShot:
                startsAt: "2026-08-02T04:00:00Z"
                duration: 1800s
        services:
          api:
            image: local/api:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
        """

        let manifest = try ManifestValidator.validated(source)
        let policy = try XCTUnwrap(manifest.maintenance)
        XCTAssertEqual(policy.timezone, "America/New_York")
        XCTAssertEqual(policy.maximumDeferral, 172_800)
        XCTAssertEqual(policy.windows.count, 2)
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
        XCTAssertTrue(canonical.contains("maintenance:"))
        XCTAssertTrue(canonical.contains("oneShot:"))
    }

    func testMaintenanceRejectsAmbiguousUnsafeAndUnconfigurableWindows() {
        let invalid = """
        version: 3
        project: demo
        maintenance:
          timezone: Not/AZone
          maximumDeferral: 0s
          windows:
            - id: BAD_ID
              actions:
                - recovery
              recurring:
                weekdays:
                  - monday
                start: "25:90"
                duration: 1s
              oneShot:
                startsAt: "tomorrow"
                duration: 1s
        services:
          api:
            image: local/api:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
        """

        XCTAssertThrowsError(try ManifestValidator.validated(invalid))
    }
}

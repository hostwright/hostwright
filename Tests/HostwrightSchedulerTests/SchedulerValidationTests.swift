import XCTest
@testable import HostwrightScheduler

final class SchedulerValidationTests: XCTestCase {
    func testValidationCodesAndStableKeysAreIndependentOfLocalizedDescription() {
        let errors: [SchedulerValidationError] = [
            .invalidResourceName("cpu"),
            .negativeResourceValue(resource: "memory", value: -1),
            .arithmeticOverflow(resource: "cpu"),
            .arithmeticUnderflow(resource: "memory"),
            .invalidField("runtime"),
            .invalidStringCollection(field: "capabilities", value: ""),
            .limitBelowRequest(resource: "cpu"),
            .allocationExceedsCapacity(resource: "memory"),
            .invalidAffinity("conflicting-label:zone"),
            .invalidTaint("malformed"),
            .invalidToleration("malformed")
        ]

        XCTAssertEqual(
            errors.map(\.code),
            [
                .invalidResourceName,
                .negativeResourceValue,
                .arithmeticOverflow,
                .arithmeticUnderflow,
                .invalidField,
                .invalidStringCollection,
                .invalidLimit,
                .invalidAllocation,
                .invalidAffinity,
                .invalidTaint,
                .invalidToleration
            ]
        )
        XCTAssertEqual(
            errors.map(\.description),
            errors.map(\.stableKey)
        )
    }

    func testUUIDOrderingUsesCanonicalCaseInsensitiveUUIDText() {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        XCTAssertEqual(
            SchedulerOrdering.uuidKey(lower),
            "00000000-0000-0000-0000-000000000001"
        )
        XCTAssertTrue(SchedulerOrdering.uuidPrecedes(lower, higher))
        XCTAssertFalse(SchedulerOrdering.uuidPrecedes(higher, lower))
    }
}

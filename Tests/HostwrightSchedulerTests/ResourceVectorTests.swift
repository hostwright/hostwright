import XCTest
@testable import HostwrightScheduler

final class ResourceVectorTests: XCTestCase {
    func testCanonicalizesZeroValuesAndSortsResourceNames() throws {
        let vector = try ResourceVector([
            "memory": 2_048,
            "cpu": 0,
            "disk": 512
        ])

        XCTAssertEqual(vector.resourceNames, ["disk", "memory"])
        XCTAssertEqual(vector.values, ["disk": 512, "memory": 2_048])
        XCTAssertEqual(vector["cpu"], 0)
    }

    func testRejectsInvalidAndNegativeValuesWithStableErrors() {
        XCTAssertThrowsError(try ResourceVector([" ": 1])) { error in
            XCTAssertEqual(
                error as? SchedulerValidationError,
                .invalidResourceName(" ")
            )
            XCTAssertEqual(
                (error as? SchedulerValidationError)?.code,
                .invalidResourceName
            )
        }

        XCTAssertThrowsError(try ResourceVector(["memory": -1])) { error in
            XCTAssertEqual(
                error as? SchedulerValidationError,
                .negativeResourceValue(resource: "memory", value: -1)
            )
            XCTAssertEqual(
                (error as? SchedulerValidationError)?.stableKey,
                "negative-resource-value:memory:-1"
            )
        }
    }

    func testArithmeticAndFitChecksUseAllNamedResources() throws {
        let base = try ResourceVector(["cpu": 2, "memory": 4_096])
        let delta = try ResourceVector(["cpu": 1, "gpu": 1])
        let capacity = try ResourceVector(["cpu": 3, "gpu": 1, "memory": 4_096])

        XCTAssertEqual(
            try base.adding(delta).values,
            ["cpu": 3, "gpu": 1, "memory": 4_096]
        )
        XCTAssertTrue(delta.fits(in: capacity))
        XCTAssertFalse(try ResourceVector(["gpu": 2]).fits(in: capacity))
        XCTAssertEqual(
            try capacity.subtracting(delta).values,
            ["cpu": 2, "memory": 4_096]
        )

        XCTAssertThrowsError(
            try base.subtracting(try ResourceVector(["gpu": 1]))
        ) { error in
            XCTAssertEqual(
                error as? SchedulerValidationError,
                .arithmeticUnderflow(resource: "gpu")
            )
        }
    }

    func testArithmeticOverflowIsStable() throws {
        let maximum = try ResourceVector(["cpu": Int64.max])
        let one = try ResourceVector(["cpu": 1])

        XCTAssertThrowsError(try maximum.adding(one)) { error in
            XCTAssertEqual(
                error as? SchedulerValidationError,
                .arithmeticOverflow(resource: "cpu")
            )
        }
    }

    func testCodableRoundTripUsesCanonicalObjectShape() throws {
        let vector = try ResourceVector(["memory": 4_096, "cpu": 2])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(vector)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "{\"cpu\":2,\"memory\":4096}"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ResourceVector.self, from: data),
            vector
        )

        let negative = Data("{\"cpu\":-1}".utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ResourceVector.self, from: negative)
        ) { error in
            XCTAssertEqual(
                error as? SchedulerValidationError,
                .negativeResourceValue(resource: "cpu", value: -1)
            )
        }
    }
}

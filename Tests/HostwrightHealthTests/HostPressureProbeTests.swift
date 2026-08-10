import Dispatch
import Foundation
import XCTest
@testable import HostwrightHealth

final class HostPressureProbeTests: XCTestCase {
    private let observationTime = Date(timeIntervalSince1970: 1_754_000_000)

    func testInjectableProbeAcceptsObservationTimeFromItsCaller() {
        let expected = HostPressureSample(observedAt: observationTime)
        let probe = FixedHostPressureProbe(sample: expected)

        XCTAssertEqual(probe.sample(at: observationTime), expected)
    }

    func testDispatchMemoryPressureEventsMapToStableSampleLevels() {
        XCTAssertEqual(
            MacOSHostPressureProbe.memoryPressureLevel(for: .normal),
            .nominal
        )
        XCTAssertEqual(
            MacOSHostPressureProbe.memoryPressureLevel(for: .warning),
            .warning
        )
        XCTAssertEqual(
            MacOSHostPressureProbe.memoryPressureLevel(for: .critical),
            .critical
        )
    }

    func testMacOSProbeReadsPublicHostFactsWithoutOwningObservationTime() {
        let probe = MacOSHostPressureProbe(
            volumeURL: URL(fileURLWithPath: "/"),
            systemMemoryPressure: .nominal,
            maintenanceState: .inactive,
            availability: .available
        )

        let sample = probe.sample(at: observationTime)

        XCTAssertEqual(sample.observedAt, observationTime)
        XCTAssertEqual(sample.systemMemoryPressure, .nominal)
        XCTAssertEqual(sample.sleepWakeState, .awake)
        XCTAssertEqual(sample.maintenanceState, .inactive)
        XCTAssertEqual(sample.availability, .available)
        XCTAssertNotEqual(sample.thermalState, .unknown)
        XCTAssertGreaterThan(sample.diskPressure.totalBytes ?? 0, 0)
        XCTAssertGreaterThan(sample.diskPressure.availableBytes ?? 0, 0)
    }

    func testInjectedPublicReadersProduceDeterministicPressureFacts() {
        let probe = MacOSHostPressureProbe(
            volumeURL: URL(fileURLWithPath: "/injected"),
            systemMemoryPressure: .warning,
            processInfoReader: FixedProcessInfoReader(
                snapshot: HostProcessInfoSnapshot(
                    thermalState: .serious,
                    isLowPowerModeEnabled: true
                )
            ),
            diskFactsReader: FixedDiskFactsReader(
                facts: HostDiskFacts(availableBytes: 15, totalBytes: 100)
            ),
            powerSourceReader: FixedPowerSourceReader(
                snapshot: HostPowerSourceSnapshot(
                    availability: .available,
                    battery: HostBatterySnapshot(
                        chargePercent: 18,
                        powerSource: .battery,
                        isCharging: false
                    )
                )
            )
        )

        let sample = probe.sample(at: observationTime)

        XCTAssertEqual(sample.thermalState, .serious)
        XCTAssertTrue(sample.isLowPowerModeEnabled)
        XCTAssertEqual(sample.systemMemoryPressure, .warning)
        XCTAssertEqual(sample.powerSourceAvailability, .available)
        XCTAssertEqual(sample.battery?.chargePercent, 18)
        XCTAssertEqual(sample.diskPressure.level, .warning)
        XCTAssertEqual(sample.diskPressure.availableBytes, 15)
        XCTAssertEqual(sample.diskPressure.totalBytes, 100)
    }

    func testInjectedPowerSourceQueryFailureIsRepresentedAsUnavailable() {
        let probe = MacOSHostPressureProbe(
            processInfoReader: FixedProcessInfoReader(
                snapshot: HostProcessInfoSnapshot(
                    thermalState: .nominal,
                    isLowPowerModeEnabled: false
                )
            ),
            diskFactsReader: FixedDiskFactsReader(
                facts: HostDiskFacts(availableBytes: 90, totalBytes: 100)
            ),
            powerSourceReader: FixedPowerSourceReader(
                snapshot: HostPowerSourceSnapshot(availability: .unavailable)
            )
        )

        let sample = probe.sample(at: observationTime)
        let decision = HostPressurePolicy().evaluate(
            sample: sample,
            previousState: .initial
        )

        XCTAssertEqual(sample.powerSourceAvailability, .unavailable)
        XCTAssertNil(sample.battery)
        XCTAssertEqual(decision.posture, .blocked)
        XCTAssertTrue(decision.reasonCodes.contains(.powerSourceUnavailable))
    }

    func testDiskThresholdConfigurationRejectsInvalidValues() {
        XCTAssertThrowsError(
            try HostDiskPressureThresholds(warningAvailablePercent: .nan)
        )
        XCTAssertThrowsError(
            try HostDiskPressureThresholds(
                warningAvailablePercent: 10,
                criticalAvailablePercent: 20
            )
        )

        let hostileData = try! JSONSerialization.data(withJSONObject: [
            "warningAvailablePercent": 20,
            "criticalAvailablePercent": 101
        ])
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                HostDiskPressureThresholds.self,
                from: hostileData
            )
        )
    }

    private struct FixedHostPressureProbe: HostPressureProbe {
        let sample: HostPressureSample

        func sample(at _: Date) -> HostPressureSample {
            sample
        }
    }

    private struct FixedProcessInfoReader: HostProcessInfoReader {
        let snapshot: HostProcessInfoSnapshot

        func read() -> HostProcessInfoSnapshot {
            snapshot
        }
    }

    private struct FixedDiskFactsReader: HostDiskFactsReader {
        let facts: HostDiskFacts?

        func read(for _: URL) -> HostDiskFacts? {
            facts
        }
    }

    private struct FixedPowerSourceReader: HostPowerSourceReader {
        let snapshot: HostPowerSourceSnapshot

        func read() -> HostPowerSourceSnapshot {
            snapshot
        }
    }
}

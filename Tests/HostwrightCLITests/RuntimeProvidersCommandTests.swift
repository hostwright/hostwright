import Foundation
import HostwrightCore
import HostwrightHealth
import HostwrightRuntime
import XCTest
@testable import HostwrightCLI

final class RuntimeProvidersCommandTests: XCTestCase {
    func testParserAcceptsOnlyRuntimeProvidersAndOptionalJSON() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["runtime", "providers"]),
            .runtimeProviders(output: .text)
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["runtime", "providers", "--json"]),
            .runtimeProviders(output: .json)
        )
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["runtime"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["runtime", "migrate"]))
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: ["runtime", "providers", "--output", "json"])
        )
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: ["runtime", "providers", "--json", "--json"])
        )
    }

    func testParserRequiresAnExplicitMigrationModeAndTargetProvider() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "runtime", "migrate", "stack.yaml", "--state-db", "/tmp/state.sqlite",
                "--to", "containerization", "--dry-run", "--json"
            ]),
            .runtimeMigrate(
                options: RuntimeProviderMigrationCLIOptions(
                    manifestPath: "stack.yaml",
                    stateDatabasePath: "/tmp/state.sqlite",
                    targetProviderID: .appleContainerization,
                    confirmationToken: nil,
                    output: .json
                )
            )
        )
        let token = RuntimeProviderMigrationPlan.confirmationPrefix + String(repeating: "a", count: 64)
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "runtime", "migrate", "--to", "apple-cli", "--confirm-migration", token
            ]),
            .runtimeMigrate(
                options: RuntimeProviderMigrationCLIOptions(
                    manifestPath: HostwrightIdentity.manifestFileName,
                    stateDatabasePath: nil,
                    targetProviderID: .appleContainerCLI,
                    confirmationToken: token,
                    output: .text
                )
            )
        )
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: [
                "runtime", "migrate", "--to", "containerization"
            ])
        )
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: [
                "runtime", "migrate", "--to", "containerization", "--dry-run",
                "--confirm-migration", token
            ])
        )
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: [
                "runtime", "migrate", "--to", "auto", "--dry-run"
            ])
        )
    }

    func testJSONDiscoveryIsDeterministicAndPrefersCompatibleCLI() throws {
        let cli = snapshot(providerID: .appleContainerCLI)
        let helper = snapshot(providerID: .appleContainerization)
        let probes = [
            RuntimeProviderProbeResult.available(helper),
            RuntimeProviderProbeResult.available(cli)
        ]
        let effects = EffectCounter()
        let environment = environment(probes: probes, effects: effects)

        let first = HostwrightCLI.run(
            arguments: ["runtime", "providers", "--json"],
            environment: environment
        )
        let second = HostwrightCLI.run(
            arguments: ["runtime", "providers", "--json"],
            environment: environment
        )

        XCTAssertEqual(first.exitCode, 0)
        XCTAssertEqual(first.standardError, "")
        XCTAssertEqual(first.standardOutput, second.standardOutput)
        let report = try JSONDecoder().decode(
            RuntimeProvidersReport.self,
            from: Data(first.standardOutput.utf8)
        )
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.kind, "runtimeProviders")
        XCTAssertEqual(
            report.providers.map(\.providerID),
            [.appleContainerCLI, .appleContainerization]
        )
        XCTAssertEqual(report.providers.map(\.state), [.available, .available])
        XCTAssertEqual(report.providers.map(\.reasons), [["compatible"], ["compatible"]])
        XCTAssertEqual(report.providers[0].capabilitySHA256, cli.canonicalSHA256)
        XCTAssertEqual(report.providers[0].snapshot, cli)
        XCTAssertEqual(report.providers[1].capabilitySHA256, helper.canonicalSHA256)
        XCTAssertEqual(report.providers[1].snapshot, helper)
        XCTAssertEqual(report.automaticSelection.state, .available)
        XCTAssertEqual(report.automaticSelection.providerID, .appleContainerCLI)
        XCTAssertEqual(report.automaticSelection.capabilitySHA256, cli.canonicalSHA256)
        XCTAssertEqual(report.automaticSelection.reason, "preferred-compatible-apple-cli")
        XCTAssertEqual(effects.snapshot(), EffectCounts())
    }

    func testUnavailableAndInvalidProbeEvidenceFailsClosedWithStableReasons() throws {
        let cli = snapshot(providerID: .appleContainerCLI)
        let probes = [
            RuntimeProviderProbeResult(
                providerID: .appleContainerization,
                snapshot: cli,
                failure: nil
            ),
            RuntimeProviderProbeResult.unavailable(
                .appleContainerCLI,
                reason: .componentUnavailable
            )
        ]

        let result = HostwrightCLI.run(
            arguments: ["runtime", "providers", "--json"],
            environment: environment(probes: probes)
        )

        XCTAssertEqual(result.exitCode, 0)
        let report = try JSONDecoder().decode(
            RuntimeProvidersReport.self,
            from: Data(result.standardOutput.utf8)
        )
        XCTAssertEqual(report.providers[0].state, .unavailable)
        XCTAssertEqual(report.providers[0].reasons, ["component-unavailable"])
        XCTAssertNil(report.providers[0].snapshot)
        XCTAssertEqual(report.providers[1].state, .unavailable)
        XCTAssertEqual(report.providers[1].reasons, ["provider-identity-mismatch"])
        XCTAssertNil(report.providers[1].snapshot)
        XCTAssertEqual(report.automaticSelection.state, .unavailable)
        XCTAssertNil(report.automaticSelection.providerID)
        XCTAssertEqual(report.automaticSelection.reason, "no-compatible-provider")
    }

    func testTextDiscoveryReportsDigestStateAndSelectionReason() {
        let cli = snapshot(providerID: .appleContainerCLI)
        let result = HostwrightCLI.run(
            arguments: ["runtime", "providers"],
            environment: environment(probes: [
                .available(cli),
                .unavailable(.appleContainerization, reason: .helperHandshakeUnavailable)
            ])
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertTrue(
            result.standardOutput.contains(
                "Automatic selection: apple-container-cli (preferred-compatible-apple-cli)"
            )
        )
        XCTAssertTrue(
            result.standardOutput.contains(
                "apple-container-cli\tavailable\t\(cli.canonicalSHA256)\tcompatible"
            )
        )
        XCTAssertTrue(
            result.standardOutput.contains(
                "apple-containerization\tunavailable\tunavailable\thelper-handshake-unavailable"
            )
        )
    }

    func testHelpDocumentsReadOnlyRuntimeProviderDiscovery() {
        let result = HostwrightCLI.run(
            arguments: ["--help"],
            environment: environment(probes: [])
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("hostwright runtime providers [--json]"))
        XCTAssertTrue(
            result.standardOutput.contains(
                "runtime providers negotiates immutable provider capabilities without changing runtime or state."
            )
        )
        XCTAssertTrue(result.standardOutput.contains("hostwright runtime providers --json"))
    }

    private func environment(
        probes: [RuntimeProviderProbeResult],
        effects: EffectCounter = EffectCounter()
    ) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: { _ in
                effects.recordFileRead()
                return false
            },
            readTextFile: { _ in
                effects.recordFileRead()
                throw CLIUsageError("unexpected file read")
            },
            writeTextFile: { _, _ in effects.recordFileWrite() },
            writeNewTextFile: { _, _ in effects.recordFileWrite() },
            executablePath: { _ in nil },
            runtimeAdapter: {
                effects.recordRuntimeAdapterAccess()
                return RuntimeAdapterFactory.defaultLocal()
            },
            runtimeProviderProbes: { probes },
            swiftVersion: { nil },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "macOS 26.0" },
            doctorSystemSnapshot: { .unavailable() }
        )
    }

    private func snapshot(
        providerID: RuntimeProviderID
    ) -> RuntimeCapabilitySnapshot {
        let components: [RuntimeProviderComponent]
        if providerID == .appleContainerCLI {
            components = [
                RuntimeProviderComponent(
                    identifier: .appleContainerCLI,
                    version: "1.1.0",
                    build: "release",
                    fingerprint: "5973b9c"
                ),
                RuntimeProviderComponent(
                    identifier: .appleContainerAPIService,
                    version: "1.1.0",
                    build: "release",
                    fingerprint: "5973b9c"
                )
            ]
        } else {
            components = [
                RuntimeProviderComponent(
                    identifier: .appleContainerizationHelper,
                    version: "0.0.2",
                    build: "release",
                    fingerprint: "abcdef0"
                ),
                RuntimeProviderComponent(
                    identifier: .containerizationHelperProtocolV1,
                    version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                    build: "release",
                    fingerprint: "abcdef1"
                ),
                RuntimeProviderComponent(
                    identifier: .appleContainerizationFramework,
                    version: RuntimeProviderCapabilityContract.containerizationFrameworkVersion,
                    build: "release",
                    fingerprint: "abcdef2"
                )
            ]
        }
        return RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: providerID,
                components: components,
                minimumMacOSVersion: RuntimeProviderMacOSVersion(major: 26),
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(major: 26),
                macOSBuild: "25A123",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map {
                RuntimeProviderFeatureStatus(
                    feature: $0,
                    state: .available,
                    reason: .implemented
                )
            }
        )
    }
}

private struct EffectCounts: Equatable {
    var fileReads = 0
    var fileWrites = 0
    var runtimeAdapterAccesses = 0
}

private final class EffectCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = EffectCounts()

    func recordFileRead() {
        lock.withLock { counts.fileReads += 1 }
    }

    func recordFileWrite() {
        lock.withLock { counts.fileWrites += 1 }
    }

    func recordRuntimeAdapterAccess() {
        lock.withLock { counts.runtimeAdapterAccesses += 1 }
    }

    func snapshot() -> EffectCounts {
        lock.withLock { counts }
    }
}

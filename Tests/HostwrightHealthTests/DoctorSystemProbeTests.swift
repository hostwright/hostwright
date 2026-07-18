import Foundation
import XCTest
@testable import HostwrightHealth

final class DoctorSystemProbeTests: XCTestCase {
    func testLiveProbeUsesPublicReadOnlyHostBoundaries() throws {
        let executable = try XCTUnwrap(CommandLine.arguments.first)

        let snapshot = DoctorSystemProbe.current(
            executablePath: executable,
            developmentBuild: true,
            containerExecutablePath: nil,
            swiftExecutablePath: "/usr/bin/swift"
        )

        XCTAssertTrue(snapshot.localNetwork.loopbackAvailable)
        XCTAssertFalse(snapshot.localNetwork.authorizationWasProbed)
        XCTAssertGreaterThan(snapshot.resourcePressure.physicalMemoryBytes, 0)
        XCTAssertNotEqual(snapshot.resourcePressure.thermalState, .unknown)
        XCTAssertTrue(snapshot.tools.contains { $0.identifier == "codesign" && $0.available })
        XCTAssertTrue(snapshot.tools.contains { $0.identifier == "gatekeeper-spctl" && $0.available })
        XCTAssertEqual(
            snapshot.tools.first { $0.identifier == "apple-container-cli" }?.available,
            false
        )
        XCTAssertNotEqual(snapshot.signingTrust.codeSignature, .unavailable)
        XCTAssertNotEqual(snapshot.signingTrust.gatekeeper, .unavailable)
    }

    func testSigningProbeUsesCodesignNotarizationRequirementForStandaloneExecutable() throws {
        let executable = try XCTUnwrap(CommandLine.arguments.first)
        let resolvedExecutable = URL(fileURLWithPath: executable)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        var commands: [DoctorSystemProbe.SigningCommand] = []

        let snapshot = DoctorSystemProbe.signingSnapshot(
            executablePath: executable,
            developmentBuild: false,
            codesignExecutablePath: "/usr/bin/codesign"
        ) { command in
            commands.append(command)
            if command.arguments.first == "--display" {
                return signingResult(
                    standardError: "Authority=Developer ID Application: Hostwright (TEAMID)\n"
                )
            }
            return signingResult()
        }

        XCTAssertEqual(
            commands,
            [
                DoctorSystemProbe.SigningCommand(
                    executablePath: "/usr/bin/codesign",
                    arguments: ["--verify", "--strict", "--verbose=2", resolvedExecutable]
                ),
                DoctorSystemProbe.SigningCommand(
                    executablePath: "/usr/bin/codesign",
                    arguments: ["--display", "--verbose=4", resolvedExecutable]
                ),
                DoctorSystemProbe.SigningCommand(
                    executablePath: "/usr/bin/codesign",
                    arguments: [
                        "-R=notarized",
                        "--check-notarization",
                        "--verify", "--verbose=2",
                        resolvedExecutable
                    ]
                )
            ]
        )
        XCTAssertEqual(snapshot.codeSignature, .developerID)
        XCTAssertEqual(snapshot.gatekeeper, .accepted)
        XCTAssertFalse(snapshot.developmentBuild)
        XCTAssertNil(snapshot.probeError)
    }

    func testSigningProbeRejectsFailedNotarizationRequirementWithoutDiscardingSignatureState() throws {
        let executable = try XCTUnwrap(CommandLine.arguments.first)

        let snapshot = DoctorSystemProbe.signingSnapshot(
            executablePath: executable,
            developmentBuild: false,
            codesignExecutablePath: "/usr/bin/codesign"
        ) { command in
            if command.arguments.first == "--display" {
                return signingResult(
                    standardError: "Authority=Developer ID Application: Hostwright (TEAMID)\n"
                )
            }
            if command.arguments.contains("-R=notarized") {
                return signingResult(
                    exitStatus: 3,
                    standardError: "test-requirement: code failed to satisfy specified code requirement(s)\n"
                )
            }
            return signingResult()
        }

        XCTAssertEqual(snapshot.codeSignature, .developerID)
        XCTAssertEqual(snapshot.gatekeeper, .rejected)
        XCTAssertNil(snapshot.probeError)
    }

    private func signingResult(
        exitStatus: Int32 = 0,
        standardOutput: String = "",
        standardError: String = ""
    ) -> DoctorSystemProbe.SigningCommandResult {
        DoctorSystemProbe.SigningCommandResult(
            exitStatus: exitStatus,
            standardOutput: Data(standardOutput.utf8),
            standardError: Data(standardError.utf8)
        )
    }
}

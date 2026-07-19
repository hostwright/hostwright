import Foundation
import XCTest
@testable import HostwrightRuntime

final class RuntimeProviderCapabilityProbeTests: XCTestCase {
    func testSupportedAppleCLIProbeIsCanonicalRepeatableAndComplete() async throws {
        let runner = RecordingProcessRunner(evidence: .supported)
        let probe = makeProbe(runner: runner)

        let first = try await probe.probeAppleContainerCLI()
        let second = try await probe.probeAppleContainerCLI()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.canonicalSHA256, second.canonicalSHA256)
        XCTAssertEqual(first.descriptor.providerID, .appleContainerCLI)
        XCTAssertEqual(
            first.descriptor.components.map(\.identifier),
            [.appleContainerCLI, .appleContainerAPIService]
        )
        XCTAssertEqual(first.descriptor.components.map(\.version), ["1.1.0", "1.1.0"])
        XCTAssertEqual(first.descriptor.components.map(\.build), ["release", "release"])
        XCTAssertEqual(first.descriptor.components.map(\.fingerprint), ["5973b9c", "5973b9c"])
        XCTAssertEqual(first.host.macOSVersion, RuntimeProviderMacOSVersion(major: 26, minor: 1))
        XCTAssertEqual(first.host.macOSBuild, "25A123")
        XCTAssertEqual(first.host.architecture, .arm64)
        XCTAssertEqual(first.features, RuntimeProviderCapabilityProbe.appleContainerCLIFeatures)
        XCTAssertEqual(RuntimeProviderCapabilityNegotiator.validationFindings(for: first), [])
    }

    func testMissingExecutableAndAPIServiceFailClosedWithoutPartialSnapshot() async throws {
        let missingRunner = RecordingProcessRunner(evidence: .supported)
        let missingProbe = makeProbe(
            runner: missingRunner,
            executables: ["sw_vers": "/usr/bin/sw_vers", "uname": "/usr/bin/uname"]
        )
        do {
            _ = try await missingProbe.probeAppleContainerCLI()
            XCTFail("Expected the missing Apple CLI to fail closed.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProviderCapabilityProbeError,
                .executableUnavailable("container")
            )
        }
        let missingSpecs = await missingRunner.recordedSpecs()
        XCTAssertEqual(missingSpecs.count, 0)

        let unavailableRunner = RecordingProcessRunner(
            evidence: ProbeEvidence(
                systemStatus: Self.notRunningSystemStatus
            )
        )
        do {
            _ = try await makeProbe(runner: unavailableRunner).probeAppleContainerCLI()
            XCTFail("Expected the unavailable API service to fail closed.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProviderCapabilityProbeError,
                .apiServiceUnavailable
            )
        }
    }

    func testMixedCLIAndAPIServiceIdentityFailsClosed() async {
        let runner = RecordingProcessRunner(
            evidence: ProbeEvidence(systemStatus: Self.mixedSystemStatus)
        )

        do {
            _ = try await makeProbe(runner: runner).probeAppleContainerCLI()
            XCTFail("Expected mixed component versions to fail closed.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProviderCapabilityProbeError,
                .invalidAPIServiceIdentity
            )
        }
    }

    func testSemanticHostOrComponentChangeProducesFreshDigestAndRejectsStaleHandshake() async throws {
        let first = try await makeProbe(
            runner: RecordingProcessRunner(evidence: .supported)
        ).probeAppleContainerCLI()
        let changed = try await makeProbe(
            runner: RecordingProcessRunner(
                evidence: ProbeEvidence(macOSBuild: "25A124")
            )
        ).probeAppleContainerCLI()
        XCTAssertNotEqual(first.canonicalSHA256, changed.canonicalSHA256)

        let helperProbe = makeProbe(runner: RecordingProcessRunner(evidence: .supported))
        let original = helperSnapshot()
        let semanticallyChanged = helperSnapshot(helperFingerprint: digest("d"))
        let stale = RuntimeContainerizationHelperCapabilityProbeInput(
            localHost: semanticallyChanged.host,
            expectedUserID: 501,
            peerIdentity: validPeerIdentity(),
            handshake: RuntimeContainerizationHelperCapabilityHandshake(
                protocolVersion: ContainerizationHelperProtocolV1.version,
                snapshot: semanticallyChanged,
                capabilitySHA256: original.canonicalSHA256
            )
        )
        XCTAssertThrowsError(try helperProbe.probeContainerizationHelper(stale)) {
            XCTAssertEqual(
                $0 as? RuntimeProviderCapabilityProbeError,
                .helperCapabilityStale
            )
        }
    }

    func testUnsupportedMacOSVersionAndArchitectureFailClosed() async {
        let unsupportedVersion = RecordingProcessRunner(
            evidence: ProbeEvidence(macOSVersion: "25.9")
        )
        do {
            _ = try await makeProbe(runner: unsupportedVersion).probeAppleContainerCLI()
            XCTFail("Expected the unsupported macOS version to fail closed.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProviderCapabilityProbeError,
                .unsupportedMacOSVersion(RuntimeProviderMacOSVersion(major: 25, minor: 9))
            )
        }

        let unsupportedArchitecture = RecordingProcessRunner(
            evidence: ProbeEvidence(architecture: "x86_64")
        )
        do {
            _ = try await makeProbe(runner: unsupportedArchitecture).probeAppleContainerCLI()
            XCTFail("Expected the unsupported architecture to fail closed.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProviderCapabilityProbeError,
                .unsupportedArchitecture("x86_64")
            )
        }
    }

    func testCancellationPropagatesWithoutProducingCapabilityEvidence() async {
        let runner = RecordingProcessRunner(evidence: .supported, cancelAtCall: 0)

        do {
            _ = try await makeProbe(runner: runner).probeAppleContainerCLI()
            XCTFail("Expected cancellation to propagate.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let specs = await runner.recordedSpecs()
        XCTAssertEqual(specs.count, 1)
    }

    func testAppleProbeRunsOnlyExactResolvedReadOnlyCommands() async throws {
        let runner = RecordingProcessRunner(evidence: .supported)
        _ = try await makeProbe(runner: runner).probeAppleContainerCLI()
        let specs = await runner.recordedSpecs()

        XCTAssertEqual(
            specs.map(\.arguments),
            [
                ["--version"],
                ["system", "status", "--format", "json"],
                ["-productVersion"],
                ["-buildVersion"],
                ["-m"]
            ]
        )
        XCTAssertTrue(specs.allSatisfy { $0.classification == .readOnly })
        XCTAssertTrue(
            specs.allSatisfy {
                $0.executableResolution == .resolvedByRuntimeExecutableResolver &&
                    $0.mutationKind == nil &&
                    $0.environment.isEmpty &&
                    $0.sensitiveValues.isEmpty
            }
        )
    }

    func testHelperProbeRequiresAuthenticatedExactHandshakeAndNeverInfersAvailability() throws {
        let probe = makeProbe(runner: RecordingProcessRunner(evidence: .supported))
        let snapshot = helperSnapshot()
        let supported = RuntimeContainerizationHelperCapabilityProbeInput(
            localHost: snapshot.host,
            expectedUserID: 501,
            peerIdentity: validPeerIdentity(),
            handshake: RuntimeContainerizationHelperCapabilityHandshake(
                protocolVersion: ContainerizationHelperProtocolV1.version,
                snapshot: snapshot,
                capabilitySHA256: snapshot.canonicalSHA256
            )
        )

        XCTAssertEqual(try probe.probeContainerizationHelper(supported), snapshot)

        let missing = RuntimeContainerizationHelperCapabilityProbeInput(
            localHost: snapshot.host,
            expectedUserID: 501,
            peerIdentity: validPeerIdentity(),
            handshake: nil
        )
        XCTAssertThrowsError(try probe.probeContainerizationHelper(missing)) {
            XCTAssertEqual(
                $0 as? RuntimeProviderCapabilityProbeError,
                .helperHandshakeUnavailable
            )
        }

        let unsupportedProtocol = RuntimeContainerizationHelperCapabilityProbeInput(
            localHost: snapshot.host,
            expectedUserID: 501,
            peerIdentity: validPeerIdentity(),
            handshake: RuntimeContainerizationHelperCapabilityHandshake(
                protocolVersion: 2,
                snapshot: snapshot,
                capabilitySHA256: snapshot.canonicalSHA256
            )
        )
        XCTAssertThrowsError(try probe.probeContainerizationHelper(unsupportedProtocol)) {
            XCTAssertEqual(
                $0 as? RuntimeProviderCapabilityProbeError,
                .helperProtocolUnsupported(2)
            )
        }

        let unauthenticated = RuntimeContainerizationHelperCapabilityProbeInput(
            localHost: snapshot.host,
            expectedUserID: 501,
            peerIdentity: ContainerizationHelperPeerIdentity(
                userID: 502,
                processID: 42,
                teamIdentifier: ContainerizationHelperPeerIdentityPolicy.expectedTeamIdentifier,
                designatedRequirement: ContainerizationHelperPeerIdentityPolicy.expectedDesignatedRequirement
            ),
            handshake: supported.handshake
        )
        XCTAssertThrowsError(try probe.probeContainerizationHelper(unauthenticated)) {
            XCTAssertEqual(
                $0 as? RuntimeProviderCapabilityProbeError,
                .helperPeerIdentityInvalid
            )
        }
    }

    private func makeProbe(
        runner: RecordingProcessRunner,
        executables: [String: String] = [
            "container": "/usr/bin/container",
            "sw_vers": "/usr/bin/sw_vers",
            "uname": "/usr/bin/uname"
        ]
    ) -> RuntimeProviderCapabilityProbe {
        RuntimeProviderCapabilityProbe(
            executableResolver: ProbeExecutableResolver(executables: executables),
            processRunner: runner
        )
    }

    private func helperSnapshot(
        helperFingerprint: String? = nil
    ) -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerization,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationHelper,
                        version: "0.0.2",
                        build: "release",
                        fingerprint: helperFingerprint ?? digest("a")
                    ),
                    RuntimeProviderComponent(
                        identifier: .containerizationHelperProtocolV1,
                        version: "1",
                        build: "canonical-json",
                        fingerprint: digest("b")
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationFramework,
                        version: "0.35.0",
                        build: "release",
                        fingerprint: digest("c")
                    )
                ],
                minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(major: 26, minor: 1),
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

    private func validPeerIdentity() -> ContainerizationHelperPeerIdentity {
        ContainerizationHelperPeerIdentity(
            userID: 501,
            processID: 42,
            teamIdentifier: ContainerizationHelperPeerIdentityPolicy.expectedTeamIdentifier,
            designatedRequirement: ContainerizationHelperPeerIdentityPolicy.expectedDesignatedRequirement
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private static let notRunningSystemStatus =
        #"{"status":"not running","apiServerVersion":"","apiServerBuild":"","apiServerCommit":"","apiServerAppName":""}"#

    private static let mixedSystemStatus =
        #"{"status":"running","apiServerVersion":"container-apiserver version 1.0.0 (build: release, commit: ee848e3)","apiServerBuild":"release","apiServerCommit":"ee848e3","apiServerAppName":"container-apiserver"}"#
}

private struct ProbeEvidence: Sendable {
    static let supported = ProbeEvidence()

    let cliVersion: String
    let systemStatus: String
    let macOSVersion: String
    let macOSBuild: String
    let architecture: String

    init(
        cliVersion: String = "container CLI version 1.1.0 (build: release, commit: 5973b9c)\n",
        systemStatus: String = #"{"status":"running","apiServerVersion":"container-apiserver version 1.1.0 (build: release, commit: 5973b9c)","apiServerBuild":"release","apiServerCommit":"5973b9c","apiServerAppName":"container-apiserver"}"#,
        macOSVersion: String = "26.1",
        macOSBuild: String = "25A123",
        architecture: String = "arm64"
    ) {
        self.cliVersion = cliVersion
        self.systemStatus = systemStatus
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.architecture = architecture
    }
}

private struct ProbeExecutableResolver: RuntimeExecutableResolving {
    let executables: [String: String]

    func resolveExecutable(named name: String) -> ResolvedRuntimeExecutable? {
        executables[name].map { ResolvedRuntimeExecutable(name: name, path: $0) }
    }
}

private actor RecordingProcessRunner: RuntimeProcessRunning {
    private let evidence: ProbeEvidence
    private let cancelAtCall: Int?
    private var specs: [RuntimeCommandSpec] = []

    init(evidence: ProbeEvidence, cancelAtCall: Int? = nil) {
        self.evidence = evidence
        self.cancelAtCall = cancelAtCall
    }

    func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        let call = specs.count
        specs.append(spec)
        if cancelAtCall == call {
            throw CancellationError()
        }

        let output: String
        switch spec.arguments {
        case ["--version"]:
            output = evidence.cliVersion
        case ["system", "status", "--format", "json"]:
            output = evidence.systemStatus
        case ["-productVersion"]:
            output = evidence.macOSVersion + "\n"
        case ["-buildVersion"]:
            output = evidence.macOSBuild + "\n"
        case ["-m"]:
            output = evidence.architecture + "\n"
        default:
            throw RuntimeProviderCapabilityProbeError.invalidProcessResult("unexpected test command")
        }

        return RuntimeCommandResult(
            spec: spec,
            exitStatus: 0,
            standardOutput: output,
            standardError: ""
        )
    }

    func recordedSpecs() -> [RuntimeCommandSpec] {
        specs
    }
}

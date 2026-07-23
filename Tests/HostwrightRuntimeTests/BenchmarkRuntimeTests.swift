import XCTest
@testable import HostwrightRuntime
import HostwrightTestSupport

final class BenchmarkRuntimeTests: XCTestCase {
    private let identifier = "hostwright-v2-bench-probe-0123456789abcdef0123456789abcdef"
    private let executable = ResolvedRuntimeExecutable(name: "container", path: "/usr/local/bin/container")

    func testStatsCommandIsExactReadOnlyAndNonStreaming() throws {
        let spec = AppleContainerCommand.spec(kind: .stats(containerID: identifier), executable: executable)
        XCTAssertEqual(spec.arguments, ["stats", identifier, "--no-stream", "--format", "json"])
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateExactResourceStats(spec, resourceIdentifier: identifier))

        let broad = RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: ["stats", "--no-stream", "--format", "json"],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "broad stats"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateExactResourceStats(broad, resourceIdentifier: identifier))
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateExactResourceStats(spec, resourceIdentifier: "hostwright-demo-api"))
    }

    func testVersionParserRequiresExactSemanticVersionToken() {
        let output = "container CLI version 1.0.0 (build: release, commit: ee848e3)"
        XCTAssertEqual(AppleContainerVersionParser.parse(output), "1.0.0")
        XCTAssertTrue(AppleContainerVersionParser.isValidExpectedVersion("1.0.0"))
        XCTAssertFalse(AppleContainerVersionParser.isValidExpectedVersion("1.0"))
        XCTAssertFalse(AppleContainerVersionParser.isValidExpectedVersion("version 1.0.0"))
        XCTAssertNil(AppleContainerVersionParser.parse("container CLI build 1.0.0"))
    }

    func testLocalImageEvidenceParserUsesExactReferenceDigestAndArm64Variant() throws {
        let descriptor = "sha256:" + String(repeating: "a", count: 64)
        let amdDigest = "sha256:" + String(repeating: "b", count: 64)
        let armDigest = "sha256:" + String(repeating: "c", count: 64)
        let text = """
        [{"configuration":{"descriptor":{"digest":"\(descriptor)"},"name":"docker.io/library/python:alpine"},"variants":[{"digest":"\(amdDigest)","platform":{"architecture":"amd64","os":"linux"}},{"digest":"\(armDigest)","platform":{"architecture":"arm64","os":"linux"}}]}]
        """
        let evidence = try AppleContainerImageEvidenceParser.parse(
            text,
            expectedReference: "docker.io/library/python:alpine",
            preferredArchitecture: "arm64"
        )
        XCTAssertEqual(evidence.descriptorDigest, descriptor)
        XCTAssertEqual(evidence.variantDigest, armDigest)
        XCTAssertEqual(evidence.architecture, "arm64")
        XCTAssertEqual(evidence.operatingSystem, "linux")
    }

    func testLocalImageEvidenceParserBlocksMissingImageAndRejectsBadDigest() {
        let validDigest = "sha256:" + String(repeating: "a", count: 64)
        let missing = "[{\"configuration\":{\"descriptor\":{\"digest\":\"\(validDigest)\"},\"name\":\"other:image\"},\"variants\":[]}]"
        XCTAssertThrowsError(
            try AppleContainerImageEvidenceParser.parse(
                missing,
                expectedReference: "python:alpine",
                preferredArchitecture: "arm64"
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeAdapterError, .capabilityUnavailable(.lifecycleMutation))
        }

        let badDigest = "[{\"configuration\":{\"descriptor\":{\"digest\":\"latest\"},\"name\":\"python:alpine\"},\"variants\":[]}]"
        XCTAssertThrowsError(
            try AppleContainerImageEvidenceParser.parse(
                badDigest,
                expectedReference: "python:alpine",
                preferredArchitecture: "arm64"
            )
        )
    }

    func testStatsParserUsesRealAppleContainerOnePointZeroShape() throws {
        let text = """
        [{"blockReadBytes":1744896,"blockWriteBytes":0,"cpuUsageUsec":1988,"id":"\(identifier)","memoryLimitBytes":1073741824,"memoryUsageBytes":2002944,"networkRxBytes":142,"networkTxBytes":602,"numProcesses":1}]
        """
        let sample = try AppleContainerStatsParser.parse(text, expectedResourceIdentifier: identifier)
        XCTAssertEqual(sample.resourceIdentifier, identifier)
        XCTAssertEqual(sample.cpuUsageMicroseconds, 1_988)
        XCTAssertEqual(sample.memoryUsageBytes, 2_002_944)
        XCTAssertEqual(sample.memoryLimitBytes, 1_073_741_824)
        XCTAssertEqual(sample.processCount, 1)
    }

    func testStatsParserRejectsWrongIdentityAndMultipleRows() {
        let wrong = """
        [{"blockReadBytes":0,"blockWriteBytes":0,"cpuUsageUsec":1,"id":"hostwright-v2-bench-probe-ffffffffffffffffffffffffffffffff","memoryLimitBytes":1,"memoryUsageBytes":1,"networkRxBytes":0,"networkTxBytes":0,"numProcesses":1}]
        """
        XCTAssertThrowsError(try AppleContainerStatsParser.parse(wrong, expectedResourceIdentifier: identifier))
        XCTAssertThrowsError(try AppleContainerStatsParser.parse(wrong + wrong, expectedResourceIdentifier: identifier))
    }

    func testReadOnlyAdapterReadsVersionAndExactStatsThroughRunner() async throws {
        let versionSpec = AppleContainerCommand.spec(kind: .version, executable: executable)
        let versionAdapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(executables: ["container": executable.path]),
            processRunner: ScriptedRuntimeProcessRunner(
                behavior: .result(
                    RuntimeCommandResult(
                        spec: versionSpec,
                        exitStatus: 0,
                        standardOutput: "container CLI version 1.0.0 (build: release, commit: ee848e3)\n",
                        standardError: ""
                    )
                )
            )
        )
        let version = try await versionAdapter.runtimeVersion()
        XCTAssertEqual(version, "1.0.0")

        let statsSpec = AppleContainerCommand.spec(kind: .stats(containerID: identifier), executable: executable)
        let statsAdapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(executables: ["container": executable.path]),
            processRunner: ScriptedRuntimeProcessRunner(
                behavior: .result(
                    RuntimeCommandResult(
                        spec: statsSpec,
                        exitStatus: 0,
                        standardOutput: "[{\"blockReadBytes\":0,\"blockWriteBytes\":0,\"cpuUsageUsec\":1,\"id\":\"\(identifier)\",\"memoryLimitBytes\":2,\"memoryUsageBytes\":1,\"networkRxBytes\":0,\"networkTxBytes\":0,\"numProcesses\":1}]",
                        standardError: ""
                    )
                )
            )
        )
        let usage = try await statsAdapter.resourceUsage(for: identifier)
        XCTAssertEqual(usage.memoryLimitBytes, 2)
    }
}

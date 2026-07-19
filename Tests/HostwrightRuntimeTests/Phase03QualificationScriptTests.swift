import Darwin
import Foundation
import XCTest

final class Phase03QualificationScriptTests: XCTestCase {
    func testHarnessKeepsQualificationSurfaceFixedAndFailClosed() throws {
        let source = try String(contentsOf: qualificationScript(), encoding: .utf8)

        for lane in [
            "apple-cli-1.0.0",
            "apple-cli-1.1.0",
            "containerization-0.35.0",
        ] {
            XCTAssertTrue(source.contains(lane), "Missing lane \(lane)")
        }
        for operation in ["conformance|migration|recovery", "RUNNER_ARGUMENTS"] {
            XCTAssertTrue(source.contains(operation), "Missing contract \(operation)")
        }
        for scenario in [
            "cli-service-restart",
            "helper-restart",
            "hostwright-termination",
            "mixed-component-versions",
            "checkpoint-crash",
            "stale-helper",
            "future-protocol-refusal",
            "downgrade-refusal",
        ] {
            XCTAssertTrue(source.contains(scenario), "Missing scenario \(scenario)")
        }

        XCTAssertTrue(source.contains("unmanagedInventoryUnchanged"))
        XCTAssertTrue(source.contains("unmanagedBeforeSHA256"))
        XCTAssertTrue(source.contains("unmanagedAfterSHA256"))
        XCTAssertTrue(source.contains("fixture image digest is invalid"))
        XCTAssertTrue(source.contains("operation-specific details contain a sensitive key"))
        XCTAssertTrue(source.contains("the harness will not pull it"))
        XCTAssertTrue(source.contains("prepare-containerization-assets.sh"))
        XCTAssertTrue(source.contains("/usr/bin/find -P \"$WORK_ROOT\" -depth -delete"))
        XCTAssertFalse(source.contains("rm -rf"))
        XCTAssertFalse(source.contains("eval "))
        XCTAssertFalse(source.contains("curl "))
        XCTAssertFalse(source.contains("image pull"))
        XCTAssertFalse(source.contains("release create"))
        XCTAssertFalse(source.contains("gh api"))
    }

    func testUnsupportedLaneStopsBeforeToolExecution() throws {
        let root = try temporaryDirectory(named: "unsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("runner-called")
        let runner = try makeRunner(in: root, marker: marker)
        let output = root.appendingPathComponent("evidence.json")

        let result = try runHarness(
            [
                "conformance",
                "--lane", "apple-cli-9.9.9",
                "--conformance-bin", runner.path,
                "--local-image", "example.invalid/local:existing",
                "--output", output.path,
            ],
            environment: [:]
        )

        XCTAssertEqual(result.status, 64, result.error)
        XCTAssertTrue(result.error.contains("unsupported Phase 03 lane"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMissingLocalAppleImageStopsWithoutPullOrRunnerMutation() throws {
        let root = try temporaryDirectory(named: "missing-image")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("runner-called")
        let runner = try makeRunner(in: root, marker: marker)
        let toolLog = root.appendingPathComponent("container.log")
        _ = try makeContainer(
            in: root,
            imagesJSON: #"[{"configuration":{"name":"example.invalid/other:local"}}]"#
        )
        let output = root.appendingPathComponent("evidence.json")

        let result = try runHarness(
            [
                "conformance",
                "--lane", "apple-cli-1.1.0",
                "--conformance-bin", runner.path,
                "--local-image", "example.invalid/required:local",
                "--output", output.path,
            ],
            environment: [
                "PATH": "\(root.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
                "FAKE_CONTAINER_LOG": toolLog.path,
                "TMPDIR": root.path,
            ]
        )

        XCTAssertEqual(result.status, 69, result.error)
        XCTAssertTrue(result.error.contains("is not present locally"))
        XCTAssertTrue(result.error.contains("will not pull"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let commands = try String(contentsOf: toolLog, encoding: .utf8)
        XCTAssertTrue(commands.contains("--version"))
        XCTAssertTrue(commands.contains("image list --format json"))
        XCTAssertFalse(commands.contains("pull"))
        try assertNoHarnessTemporaryArtifacts(in: root)
    }

    func testPassingFixtureProducesCanonicalBoundedEvidenceAndExactCleanup() throws {
        let root = try temporaryDirectory(named: "passing")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("runner-called")
        let image = "example.invalid/fixture:local"
        let runner = try makeRunner(in: root, marker: marker)
        _ = try makeContainer(
            in: root,
            imagesJSON: "[{\"configuration\":{\"name\":\"\(image)\"}}]"
        )
        let output = root.appendingPathComponent("evidence.json")

        let result = try runHarness(
            [
                "conformance",
                "--lane", "apple-cli-1.1.0",
                "--conformance-bin", runner.path,
                "--local-image", image,
                "--output", output.path,
            ],
            environment: [
                "PATH": "\(root.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
                "FAKE_CONTAINER_LOG": root.appendingPathComponent("container.log").path,
                "TMPDIR": root.path,
            ]
        )

        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertTrue(result.output.contains("Phase 03 conformance evidence passed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let data = try Data(contentsOf: output)
        XCTAssertLessThan(data.count, 8 * 1_024 * 1_024)
        XCTAssertEqual(data.last, 0x0A)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "phase03QualificationEvidence")
        XCTAssertEqual(object["operation"] as? String, "conformance")
        let runnerEvidence = try XCTUnwrap(object["runnerEvidence"] as? [String: Any])
        XCTAssertEqual(runnerEvidence["status"] as? String, "passed")
        let details = try XCTUnwrap(runnerEvidence["details"] as? [String: Any])
        let cases = try XCTUnwrap(details["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.first?["status"] as? String, "passed")
        let commands = try XCTUnwrap(runnerEvidence["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.compactMap { $0["exitStatus"] as? Int }, [0, 64])
        let fixture = try XCTUnwrap(runnerEvidence["fixtureImage"] as? [String: Any])
        XCTAssertEqual(fixture["reference"] as? String, image)
        XCTAssertEqual(
            fixture["digest"] as? String,
            "sha256:" + String(repeating: "c", count: 64)
        )
        let invocation = try XCTUnwrap(object["runnerInvocation"] as? [String: Any])
        let arguments = try XCTUnwrap(invocation["arguments"] as? [String])
        XCTAssertEqual(arguments.first, "hostwright-runtime-conformance")
        XCTAssertTrue(arguments.contains("<runner-output>"))
        XCTAssertEqual(invocation["exitStatus"] as? Int, 0)
        try assertNoHarnessTemporaryArtifacts(in: root)
    }

    func testChangedUnmanagedInventoryRejectsEvidenceAndCleansTemporaryFiles() throws {
        let root = try temporaryDirectory(named: "changed-unmanaged")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = "example.invalid/fixture:local"
        let runner = try makeRunner(
            in: root,
            marker: root.appendingPathComponent("runner-called")
        )
        _ = try makeContainer(
            in: root,
            imagesJSON: "[{\"configuration\":{\"name\":\"\(image)\"}}]"
        )
        let output = root.appendingPathComponent("evidence.json")

        let result = try runHarness(
            [
                "conformance",
                "--lane", "apple-cli-1.1.0",
                "--conformance-bin", runner.path,
                "--local-image", image,
                "--output", output.path,
            ],
            environment: [
                "PATH": "\(root.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
                "FAKE_CONTAINER_LOG": root.appendingPathComponent("container.log").path,
                "FAKE_UNMANAGED_AFTER": String(repeating: "e", count: 64),
                "TMPDIR": root.path,
            ]
        )

        XCTAssertEqual(result.status, 70, result.error)
        XCTAssertTrue(result.error.contains("unmanaged inventory hashes differ"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoHarnessTemporaryArtifacts(in: root)
    }

    private func qualificationScript() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/phase03-qualification.sh")
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-phase03-script-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedPath = root.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: try XCTUnwrap(resolvedPath))
    }

    private func makeContainer(in root: URL, imagesJSON: String) throws -> URL {
        let executable = root.appendingPathComponent("container")
        let source = """
        #!/bin/bash
        set -euo pipefail
        printf '%s\\n' "$*" >> "$FAKE_CONTAINER_LOG"
        if [[ "${1-}" == "--version" ]]; then
          printf '%s\\n' 'container CLI version 1.1.0'
          exit 0
        fi
        if [[ "${1-}" == "image" && "${2-}" == "list" && "${3-}" == "--format" && "${4-}" == "json" ]]; then
          printf '%s\\n' '\(imagesJSON)'
          exit 0
        fi
        exit 64
        """
        try writeExecutable(source, to: executable)
        return executable
    }

    private func makeRunner(in root: URL, marker: URL) throws -> URL {
        let executable = root.appendingPathComponent("hostwright-runtime-conformance")
        let source = """
        #!/bin/bash
        set -euo pipefail
        if [[ "${1-}" == "--version" ]]; then
          printf '%s\\n' 'hostwright-runtime-conformance 0.0.2-test'
          exit 0
        fi
        printf '%s\\n' called > '\(marker.path)'
        operation="${1-}"
        shift
        provider=''
        expected=''
        image=''
        output=''
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --provider) provider="$2"; shift 2 ;;
            --expected-version) expected="$2"; shift 2 ;;
            --local-image) image="$2"; shift 2 ;;
            --output) output="$2"; shift 2 ;;
            *) exit 64 ;;
          esac
        done
        /usr/bin/python3 - "$output" "$operation" "$provider" "$expected" "$image" <<'PY'
        import json
        import os
        import sys

        output, operation, provider, version, image = sys.argv[1:]
        report = {
            "schemaVersion": 1,
            "kind": "runtimeProviderConformanceEvidence",
            "status": "passed",
            "subjects": [{"providerID": provider, "providerVersion": version}],
            "fixtureImage": {"reference": image, "digest": "sha256:" + "c" * 64},
            "inventory": {
                "beforeSHA256": "a" * 64,
                "afterSHA256": "b" * 64,
                "unmanagedBeforeSHA256": "d" * 64,
                "unmanagedAfterSHA256": os.environ.get("FAKE_UNMANAGED_AFTER", "d" * 64),
            },
            "unmanagedInventoryUnchanged": True,
            "summary": {"passed": 17, "failed": 0},
            "details": {"cases": [{"identifier": "capability-negotiation", "status": "passed"}]},
            "commands": [
                {"arguments": ["container", "list", "--format", "json"], "exitStatus": 0},
                {"arguments": ["container", "start", "missing-fixture"], "exitStatus": 64},
            ],
            "cleanup": {"complete": True, "identifiers": ["fixture-resource"]},
        }
        with open(output, "w", encoding="utf-8") as handle:
            json.dump(report, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\\n")
        PY
        """
        try writeExecutable(source, to: executable)
        return executable
    }

    private func writeExecutable(_ source: String, to url: URL) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func runHarness(
        _ arguments: [String],
        environment overrides: [String: String]
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [qualificationScript().path] + arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            environment[key] = value
        }
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func assertNoHarnessTemporaryArtifacts(in root: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(entries.contains { $0.lastPathComponent.hasPrefix("hostwright-phase03.") })
        XCTAssertFalse(entries.contains { $0.lastPathComponent.hasPrefix(".hostwright-phase03-evidence.") })
    }
}

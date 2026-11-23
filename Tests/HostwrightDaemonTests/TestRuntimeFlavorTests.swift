import Foundation
import HostwrightRuntime
import XCTest

final class TestRuntimeFlavorTests: XCTestCase {
    func testNormalProviderCatalogStaysClosed() {
        XCTAssertEqual(RuntimeProviderID.knownValues, [.appleContainerCLI, .appleContainerization])
    }

    #if HOSTWRIGHT_TEST_RUNTIME
    func testFlaggedDaemonRecordsActionsWithNoContainerTools() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hostwright-test-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("hostwright.yaml")
        let digest = String(repeating: "a", count: 64)
        try """
            version: 3
            project: rehearsal
            imagePolicy: require-digest
            services:
              web:
                image: registry.invalid/web@sha256:\(digest)
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
              api:
                image: registry.invalid/api@sha256:\(digest)
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """.write(to: manifest, atomically: true, encoding: .utf8)

        let result = try runDaemon(
            arguments: ["--test-runtime", "--foreground", "--config", manifest.path],
            environment: ["HOME": directory.path, "PATH": directory.path]
        )

        guard result.status == 0 else {
            XCTFail(result.output)
            return
        }
        let report = try JSONDecoder().decode(Report.self, from: Data(result.output.utf8))
        XCTAssertEqual(report.provider, "hostwright-test-recording-v1")
        XCTAssertEqual(report.actions.map(\.kind), ["create", "create"])
        XCTAssertEqual(report.actions.map(\.service), ["api", "web"])
        XCTAssertTrue(report.actions.allSatisfy { !$0.resource.isEmpty })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["hostwright.yaml"])
    }

    private struct Report: Decodable {
        struct Action: Decodable {
            let kind: String
            let service: String
            let resource: String
        }

        let provider: String
        let actions: [Action]
    }
    #else
    func testDefaultDaemonRefusesRecordingRuntime() throws {
        let result = try runDaemon(arguments: ["--test-runtime", "--foreground", "--config", "/unused/manifest.yaml"])
        XCTAssertEqual(result.status, 64, result.output)
        XCTAssertTrue(result.output.contains("Unsupported argument '--test-runtime'"), result.output)
    }
    #endif

    private func runDaemon(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("hostwrightd")
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

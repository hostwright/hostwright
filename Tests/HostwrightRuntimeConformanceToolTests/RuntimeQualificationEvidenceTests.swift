import Foundation
import XCTest
@testable import HostwrightRuntimeConformanceTool

final class RuntimeQualificationEvidenceTests: XCTestCase {
    private struct SampleReport: Codable, Equatable {
        let count: Int
        let status: String
    }

    func testCommandRecorderNormalizesBasenamesAndDeduplicates() async throws {
        let recorder = RuntimeQualificationCommandRecorder()

        await recorder.record(
            arguments: ["/usr/local/bin/container", "system", "start"],
            exitStatus: 0
        )
        await recorder.record(
            arguments: ["/opt/homebrew/bin/container", "system", "start"],
            exitStatus: 0
        )

        let evidence = try await recorder.evidence()
        XCTAssertEqual(
            evidence,
            [.init(arguments: ["container", "system", "start"], exitStatus: 0)]
        )
    }

    func testCommandRecorderFailsClosedForSensitiveArguments() async {
        let recorder = RuntimeQualificationCommandRecorder()

        await recorder.record(
            arguments: ["/usr/bin/env", "AUTHORIZATION=Bearer secret-value"],
            exitStatus: 0
        )

        do {
            _ = try await recorder.evidence()
            XCTFail("Expected sensitive command evidence to fail closed.")
        } catch let error as RuntimeQualificationEvidenceError {
            XCTAssertEqual(error, .invalidEvidence)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEvidenceWriterCreates0600AtomicJSONWithTrailingNewline() throws {
        try withTemporaryDirectory { directory in
            let output = directory.appendingPathComponent("evidence.json")
            try RuntimeQualificationEvidenceWriter.write(
                SampleReport(count: 1, status: "passed"),
                to: output
            )

            let data = try Data(contentsOf: output)
            XCTAssertEqual(data.last, 0x0a)

            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(object["status"] as? String, "passed")
            XCTAssertEqual(object["count"] as? Int, 1)

            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "runtime-qualification-evidence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

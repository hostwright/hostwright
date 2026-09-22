import Foundation
import XCTest
@testable import HostwrightManifest

final class HostwrightManifestTests: XCTestCase {
    func assertManifestFailure(_ text: String, code expectedCode: String? = nil, contains expectedText: String) {
        XCTAssertThrowsError(try ManifestValidator.validated(text)) { error in
            guard let manifestError = error as? ManifestParseError else {
                return XCTFail("Expected ManifestParseError, got \(error).")
            }
            XCTAssertTrue(
                manifestError.issues.contains { issue in
                    (expectedCode == nil || issue.code.rawValue == expectedCode) && issue.message.contains(expectedText)
                },
                "Expected issue containing '\(expectedText)' with code \(expectedCode ?? "<any>"), got \(manifestError.issues)."
            )
        }
    }

    static let validManifest = """
    version: 3
    project: api-local

    services:
      api:
        image: ghcr.io/example/api:latest
        resources:
          requests: {cpus: 1, memory: 512MiB}
          limits: {cpus: 1, memory: 512MiB}
        ports:
          - "8080:8080"
        health:
          command: ["curl", "-f", "http://localhost:8080/health"]
          interval: 10s
        restart:
          policy: on-failure

    """

    func read(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: url.appendingPathComponent("README.md").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                throw NSError(domain: "HostwrightManifestTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not locate package root."])
            }
            url = parent
        }
    }
}

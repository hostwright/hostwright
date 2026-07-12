import Foundation
import HostwrightCore
import HostwrightExtensions
import HostwrightPolicy
import XCTest

final class ExecutableExtensionDocumentTests: XCTestCase {
    func testParserAcceptsExactReviewedLocalReadOnlyDeclaration() throws {
        let data = try encodedDocument()
        let artifact = try ExecutableExtensionDocumentParser.parse(data)

        XCTAssertEqual(artifact.document.identifier, "dev.hostwright.integration")
        XCTAssertEqual(artifact.document.capability, .diagnosticsRead)
        XCTAssertEqual(artifact.declarationSHA256.count, 64)
        XCTAssertEqual(
            ExtensionPolicyEvaluator.default.evaluate(artifact.document.policyDeclaration).map(\.reasonCode),
            [.extensionDeclared]
        )
    }

    func testParserRejectsUnknownAndMissingFieldsWithoutEchoingUnknownValues() throws {
        var object = try jsonObject()
        object["unexpected"] = "token=must-not-leak"
        let unknown = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        assertDiagnostic(tryParse: { try ExecutableExtensionDocumentParser.parse(unknown) }, code: .extensionInvalid) {
            XCTAssertFalse($0.message.contains("must-not-leak"))
        }

        object.removeValue(forKey: "unexpected")
        object.removeValue(forKey: "purpose")
        let missing = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        assertDiagnostic(tryParse: { try ExecutableExtensionDocumentParser.parse(missing) }, code: .extensionInvalid)
    }

    func testParserRejectsDuplicateTopLevelFields() throws {
        let text = String(decoding: try encodedDocument(), as: UTF8.self)
        let duplicate = text.replacingOccurrences(
            of: "\"apiVersion\":1,",
            with: "\"apiVersion\":1,\"apiVersion\":1,"
        )
        assertDiagnostic(
            tryParse: { try ExecutableExtensionDocumentParser.parse(duplicate) },
            code: .extensionInvalid
        ) {
            XCTAssertTrue($0.message.contains("duplicate field 'apiVersion'"))
        }

        let escapedDuplicate = text.replacingOccurrences(
            of: "\"apiVersion\":1,",
            with: "\"apiVersion\":1,\"\\u0061piVersion\":1,"
        )
        assertDiagnostic(
            tryParse: { try ExecutableExtensionDocumentParser.parse(escapedDuplicate) },
            code: .extensionInvalid
        )
    }

    func testParserRejectsUnsupportedVersionsAndTrust() throws {
        try assertDocumentMutation(code: .extensionInvalid) { $0["apiVersion"] = 2 }
        try assertDocumentMutation(code: .extensionInvalid) { $0["protocolVersion"] = 2 }
        try assertDocumentMutation(code: .extensionBlocked) { $0["trust"] = "thirdParty" }
        try assertDocumentMutation(code: .extensionBlocked) { $0["trust"] = "untrusted" }
    }

    func testParserRejectsMutableOrMismatchedCapabilities() throws {
        try assertDocumentMutation(code: .extensionBlocked) { object in
            object["capability"] = "runtimeMutation"
        }
        try assertDocumentMutation(code: .extensionBlocked) { object in
            object["kind"] = "schedulerIntegration"
        }
        try assertDocumentMutation(code: .extensionBlocked) { object in
            object["kind"] = "networkingProvider"
            object["capability"] = "networkingConfiguration"
        }
    }

    func testParserRejectsInvalidIdentityPurposeDigestAndBoundaries() throws {
        try assertDocumentMutation(code: .extensionInvalid) { $0["identifier"] = "Not Stable" }
        try assertDocumentMutation(code: .extensionInvalid) { $0["identifier"] = "dev.-invalid" }
        try assertDocumentMutation(code: .extensionInvalid) { $0["purpose"] = "  " }
        try assertDocumentMutation(code: .extensionInvalid) { $0["executableSHA256"] = "abc" }
        try assertDocumentMutation(code: .extensionInvalid) { $0["boundaries"] = [] }
        try assertDocumentMutation(code: .extensionInvalid) { object in
            object["boundaries"] = [
                "stateStore",
                "explicitStatePath",
                "redaction",
                "auditTrail",
                "localOnlyNoUpload",
                "noRuntimeMutation",
                "noRuntimeMutation"
            ]
        }
    }

    func testParserRejectsOversizedDocument() {
        let data = Data(repeating: 65, count: ExecutableExtensionDocumentParser.maximumDocumentBytes + 1)
        assertDiagnostic(
            tryParse: { try ExecutableExtensionDocumentParser.parse(data) },
            code: .extensionInvalid
        )
    }

    private func assertDocumentMutation(
        code: HostwrightErrorCode,
        mutate: (inout [String: Any]) -> Void
    ) throws {
        var object = try jsonObject()
        mutate(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        assertDiagnostic(tryParse: { try ExecutableExtensionDocumentParser.parse(data) }, code: code)
    }

    private func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedDocument()) as? [String: Any]
        )
    }

    private func encodedDocument() throws -> Data {
        let document = ExecutableExtensionDocument(
            kind: .diagnosticsIntegration,
            identifier: "dev.hostwright.integration",
            trust: .reviewedLocal,
            capability: .diagnosticsRead,
            purpose: "Verify the reviewed-local handshake boundary.",
            boundaries: [
                .stateStore,
                .explicitStatePath,
                .redaction,
                .auditTrail,
                .localOnlyNoUpload,
                .noRuntimeMutation
            ],
            executableSHA256: String(repeating: "a", count: 64)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private func assertDiagnostic<T>(
        tryParse: () throws -> T,
        code: HostwrightErrorCode,
        inspect: (HostwrightDiagnostic) -> Void = { _ in }
    ) {
        XCTAssertThrowsError(try tryParse()) { error in
            guard let diagnostic = error as? HostwrightDiagnostic else {
                return XCTFail("Expected HostwrightDiagnostic, got \(error)")
            }
            XCTAssertEqual(diagnostic.code.rawValue, code.rawValue)
            inspect(diagnostic)
        }
    }
}

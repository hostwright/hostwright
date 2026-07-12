import Foundation
import HostwrightCore
import HostwrightPolicy

public struct ExtensionHostConfiguration: Equatable, Sendable {
    public let timeoutMilliseconds: Int
    public let maximumOutputBytes: Int
    public let stagingRootURL: URL

    public init(
        timeoutMilliseconds: Int = 5_000,
        maximumOutputBytes: Int = 64 * 1_024,
        stagingRootURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumOutputBytes = maximumOutputBytes
        self.stagingRootURL = stagingRootURL
    }
}

public struct ReviewedLocalExtensionHost: Sendable {
    public let configuration: ExtensionHostConfiguration

    public init(configuration: ExtensionHostConfiguration = ExtensionHostConfiguration()) {
        self.configuration = configuration
    }

    public func check(
        declarationURL: URL,
        executableURL: URL
    ) throws -> ExtensionHandshakeResult {
        guard (100...30_000).contains(configuration.timeoutMilliseconds),
              (1_024...(1_024 * 1_024)).contains(configuration.maximumOutputBytes) else {
            throw executionFailed("The reviewed-local extension host limits are invalid.")
        }

        let declarationData = try ExtensionFileSecurity.readDeclaration(at: declarationURL)
        let artifact = try ExecutableExtensionDocumentParser.parse(declarationData)
        try validatePolicy(artifact.document)

        let staged = try ExtensionFileSecurity.stageExecutable(
            at: executableURL,
            rootURL: configuration.stagingRootURL
        )
        var handshakeResult: ExtensionHandshakeResult?
        var primaryError: Error?

        do {
            guard staged.sha256 == artifact.document.executableSHA256 else {
                throw invalid("The extension executable SHA-256 does not match the reviewed declaration.")
            }
            handshakeResult = try performHandshake(artifact: artifact, staged: staged)
        } catch {
            primaryError = error
        }

        do {
            try staged.cleanup()
        } catch {
            if primaryError != nil {
                throw executionFailed("The extension handshake failed and exact staging cleanup also failed.")
            }
            throw error
        }

        if let primaryError {
            throw primaryError
        }
        guard let handshakeResult else {
            throw executionFailed("The extension handshake produced no result.")
        }
        return handshakeResult
    }

    private func validatePolicy(_ document: ExecutableExtensionDocument) throws {
        let decisions = ExtensionPolicyEvaluator.default.evaluate(document.policyDeclaration)
        let blockers = decisions.filter { $0.severity == .blocker }
        guard blockers.isEmpty else {
            let reasonCodes = blockers.map(\.reasonCode.rawValue).sorted().joined(separator: ", ")
            throw blocked("The reviewed-local extension declaration is blocked by policy: \(reasonCodes).")
        }
        guard decisions.contains(where: {
            $0.severity == .allow &&
                $0.reasonCode == .extensionDeclared &&
                $0.subject == document.capability.rawValue
        }) else {
            throw blocked("The reviewed-local extension declaration did not receive an explicit capability allow decision.")
        }
    }

    private func performHandshake(
        artifact: ExecutableExtensionArtifact,
        staged: StagedExtensionExecutable
    ) throws -> ExtensionHandshakeResult {
        let requestID = UUID().uuidString.lowercased()
        let request = ExtensionHandshakeRequest(
            protocolVersion: artifact.document.protocolVersion,
            operation: "handshake",
            requestID: requestID,
            extensionIdentifier: artifact.document.identifier,
            declarationSHA256: artifact.declarationSHA256,
            capability: artifact.document.capability
        )
        let requestData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            requestData = try encoder.encode(request) + Data("\n".utf8)
        } catch {
            throw executionFailed("Could not encode the reviewed-local extension handshake request.")
        }

        let outcome = try ExtensionHandshakeProcessRunner().run(
            executableURL: staged.executableURL,
            request: requestData,
            timeoutMilliseconds: configuration.timeoutMilliseconds,
            maximumOutputBytes: configuration.maximumOutputBytes
        )
        guard !outcome.outputOverflowed, !outcome.errorOverflowed else {
            throw executionFailed("The reviewed-local extension exceeded the bounded output limit.")
        }
        guard outcome.exitStatus == 0 else {
            throw executionFailed("The reviewed-local extension process exited unsuccessfully.")
        }
        guard outcome.standardError.isEmpty else {
            throw executionFailed("The reviewed-local extension wrote unexpected standard error output.")
        }

        let response = try decodeResponse(outcome.standardOutput)
        guard response.protocolVersion == artifact.document.protocolVersion,
              response.requestID == requestID,
              response.extensionIdentifier == artifact.document.identifier,
              response.declarationSHA256 == artifact.declarationSHA256,
              response.capability == artifact.document.capability,
              response.status == "ready" else {
            throw executionFailed("The reviewed-local extension handshake response did not match the exact request and declaration binding.")
        }

        return ExtensionHandshakeResult(
            identifier: artifact.document.identifier,
            capability: artifact.document.capability,
            protocolVersion: artifact.document.protocolVersion,
            declarationSHA256: artifact.declarationSHA256,
            executableSHA256: staged.sha256,
            durationMilliseconds: outcome.durationMilliseconds,
            cleanupSucceeded: true
        )
    }

    private func decodeResponse(_ data: Data) throws -> ExtensionHandshakeResponse {
        guard !data.isEmpty else {
            throw executionFailed("The reviewed-local extension returned an empty handshake response.")
        }
        do {
            try StrictExtensionJSONObject.validate(
                data,
                expectedKeys: [
                    "protocolVersion",
                    "requestID",
                    "extensionIdentifier",
                    "declarationSHA256",
                    "capability",
                    "status"
                ],
                role: "extension handshake response"
            )
            return try JSONDecoder().decode(ExtensionHandshakeResponse.self, from: data)
        } catch let diagnostic as HostwrightDiagnostic {
            throw HostwrightDiagnostic(code: .extensionExecutionFailed, message: diagnostic.message)
        } catch {
            throw executionFailed("The reviewed-local extension returned malformed handshake JSON.")
        }
    }

    private func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionInvalid, message: message)
    }

    private func blocked(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionBlocked, message: message)
    }

    private func executionFailed(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionExecutionFailed, message: message)
    }
}

private struct ExtensionHandshakeRequest: Encodable, Sendable {
    let protocolVersion: Int
    let operation: String
    let requestID: String
    let extensionIdentifier: String
    let declarationSHA256: String
    let capability: HostwrightExtensionCapability
}

private struct ExtensionHandshakeResponse: Decodable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let extensionIdentifier: String
    let declarationSHA256: String
    let capability: HostwrightExtensionCapability
    let status: String
}

import Foundation
import HostwrightCore
@testable import HostwrightRegistry
import XCTest

final class RegistryCredentialLookupTests: XCTestCase {
    func testDockerHubInlineCredentialUsesCanonicalExactMatch() throws {
        let auth = Data("developer:password-value".utf8).base64EncodedString()
        let document = try configurationDocument(
            [
                "auths": [
                    "https://index.docker.io/v1/": ["auth": auth]
                ]
            ],
            source: .dockerAuthFile
        )
        let lookup = DockerRegistryCredentialLookup(
            helperResolver: FixedDockerCredentialHelperResolver(executables: [:])
        )

        let result = try lookup.lookup(
            for: "docker.io",
            configurationDocuments: [document]
        )

        XCTAssertEqual(result.source, .dockerAuthFile)
        XCTAssertEqual(result.kind, .password)
        XCTAssertEqual(result.credential.username, "developer")
        XCTAssertEqual(result.credential.withSecret { $0 }, "password-value")
        XCTAssertFalse(result.description.contains("password-value"))
        XCTAssertFalse(result.debugDescription.contains("password-value"))
        XCTAssertFalse(document.description.contains(auth))
        XCTAssertFalse(document.debugDescription.contains(auth))
    }

    func testOCIIdentityTokenIsTypedAndSourceIsStable() throws {
        let document = try configurationDocument(
            [
                "auths": [
                    "registry.example.com": ["identitytoken": "identity-token-value"]
                ]
            ],
            source: .ociAuthFile
        )
        let lookup = DockerRegistryCredentialLookup(
            helperResolver: FixedDockerCredentialHelperResolver(executables: [:])
        )

        let result = try lookup.lookup(
            for: "https://registry.example.com",
            configurationDocuments: [document]
        )

        XCTAssertEqual(result.source.rawValue, "oci-auth-file")
        XCTAssertEqual(result.kind, .identityToken)
        XCTAssertEqual(result.credential.username, "<token>")
        XCTAssertEqual(result.credential.withSecret { $0 }, "identity-token-value")
    }

    func testExactRegistryKeyDoesNotUseSuffixOrPrefixMatch() throws {
        let auth = Data("developer:password-value".utf8).base64EncodedString()
        let document = try configurationDocument(
            ["auths": ["registry.example.com": ["auth": auth]]],
            source: .dockerAuthFile
        )
        let lookup = DockerRegistryCredentialLookup(
            helperResolver: FixedDockerCredentialHelperResolver(executables: [:])
        )

        XCTAssertThrowsError(
            try lookup.lookup(
                for: "evil.registry.example.com",
                configurationDocuments: [document]
            )
        ) { error in
            XCTAssertEqual(error as? RegistryCredentialLookupError, .credentialUnavailable)
        }
    }

    func testCredentialHelperOverrideWinsOverCredsStoreAndInlineAuth() throws {
        let helper = RecordingCredentialHelperExecutor(
            output: helperOutput(
                serverURL: "https://registry.example.com",
                username: "helper-user",
                secret: "helper-secret"
            )
        )
        let auth = Data("inline-user:inline-secret".utf8).base64EncodedString()
        let document = try configurationDocument(
            [
                "auths": ["registry.example.com": ["auth": auth]],
                "credHelpers": ["registry.example.com": "special"],
                "credsStore": "global"
            ],
            source: .dockerAuthFile
        )
        let lookup = DockerRegistryCredentialLookup(
            helperResolver: FixedDockerCredentialHelperResolver(
                executables: [
                    "special": URL(fileURLWithPath: "/trusted/docker-credential-special"),
                    "global": URL(fileURLWithPath: "/trusted/docker-credential-global")
                ]
            ),
            helperExecutor: helper
        )

        let result = try lookup.lookup(
            for: "registry.example.com",
            configurationDocuments: [document]
        )

        XCTAssertEqual(result.source, .dockerHelper)
        XCTAssertEqual(result.credential.username, "helper-user")
        XCTAssertEqual(result.credential.withSecret { $0 }, "helper-secret")
        XCTAssertEqual(helper.calls.map(\.helperName), ["special"])
        XCTAssertEqual(helper.calls.map(\.registry.value), ["registry.example.com"])
    }

    func testCredsStoreAppliesWhenThereIsNoExactHelperOverride() throws {
        let helper = RecordingCredentialHelperExecutor(
            output: helperOutput(
                serverURL: "registry.example.com",
                username: "<token>",
                secret: "helper-token"
            )
        )
        let document = try configurationDocument(
            [
                "credHelpers": ["another.example.com": "special"],
                "credsStore": "global"
            ],
            source: .dockerAuthFile
        )
        let lookup = DockerRegistryCredentialLookup(
            helperResolver: FixedDockerCredentialHelperResolver(
                executables: [
                    "global": URL(fileURLWithPath: "/trusted/docker-credential-global")
                ]
            ),
            helperExecutor: helper
        )

        let result = try lookup.lookup(
            for: "registry.example.com",
            configurationDocuments: [document]
        )

        XCTAssertEqual(result.kind, .identityToken)
        XCTAssertEqual(helper.calls.map(\.helperName), ["global"])
    }

    func testCanonicalDuplicateEntriesFailClosed() throws {
        let auth = Data("user:secret".utf8).base64EncodedString()
        let document = try configurationDocument(
            [
                "auths": [
                    "docker.io": ["auth": auth],
                    "https://index.docker.io/v1/": ["auth": auth]
                ]
            ],
            source: .dockerAuthFile
        )
        let lookup = DockerRegistryCredentialLookup(
            helperResolver: FixedDockerCredentialHelperResolver(executables: [:])
        )

        XCTAssertThrowsError(
            try lookup.lookup(for: "docker.io", configurationDocuments: [document])
        ) { error in
            XCTAssertEqual(error as? RegistryCredentialLookupError, .ambiguousConfiguration)
        }
    }

    func testConfigurationAndCredentialBoundsFailWithoutReflectingValues() throws {
        let oversized = DockerCredentialConfigurationDocument(
            data: Data(repeating: 65, count: DockerRegistryCredentialLookup.maximumConfigurationBytes + 1),
            source: .dockerAuthFile
        )
        let lookup = DockerRegistryCredentialLookup(
            helperResolver: FixedDockerCredentialHelperResolver(executables: [:])
        )

        XCTAssertThrowsError(
            try lookup.lookup(
                for: "registry.example.com",
                configurationDocuments: [oversized]
            )
        ) { error in
            XCTAssertEqual(error as? RegistryCredentialLookupError, .configurationTooLarge)
            XCTAssertFalse(String(describing: error).contains("registry.example.com"))
        }

        let invalidSecret = String(repeating: "s", count: DockerRegistryCredentialLookup.maximumCredentialBytes + 1)
        let document = try configurationDocument(
            ["auths": ["registry.example.com": ["identitytoken": invalidSecret]]],
            source: .dockerAuthFile
        )
        XCTAssertThrowsError(
            try lookup.lookup(
                for: "registry.example.com",
                configurationDocuments: [document]
            )
        ) { error in
            XCTAssertEqual(error as? RegistryCredentialLookupError, .invalidConfiguration)
            XCTAssertFalse(String(describing: error).contains(invalidSecret))
        }
    }

    func testMismatchedHelperServerAndUnknownFieldsFailClosed() throws {
        let helper = RecordingCredentialHelperExecutor(
            output: helperOutput(
                serverURL: "different.example.com",
                username: "user",
                secret: "secret",
                additional: ["Unexpected": "value"]
            )
        )
        let document = try configurationDocument(
            ["credHelpers": ["registry.example.com": "special"]],
            source: .dockerAuthFile
        )
        let lookup = DockerRegistryCredentialLookup(
            helperResolver: FixedDockerCredentialHelperResolver(
                executables: [
                    "special": URL(fileURLWithPath: "/trusted/docker-credential-special")
                ]
            ),
            helperExecutor: helper
        )

        XCTAssertThrowsError(
            try lookup.lookup(
                for: "registry.example.com",
                configurationDocuments: [document]
            )
        ) { error in
            XCTAssertEqual(error as? RegistryCredentialLookupError, .invalidHelperOutput)
        }
    }

    func testCancellationStopsBeforeConfigurationOrHelperAccess() throws {
        let helper = RecordingCredentialHelperExecutor(
            output: helperOutput(
                serverURL: "registry.example.com",
                username: "user",
                secret: "secret"
            )
        )
        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()
        let lookup = DockerRegistryCredentialLookup(
            helperResolver: FixedDockerCredentialHelperResolver(executables: [:]),
            helperExecutor: helper
        )

        XCTAssertThrowsError(
            try lookup.lookup(
                for: "registry.example.com",
                configurationDocuments: [],
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(error as? RegistryCredentialLookupError, .cancelled)
        }
        XCTAssertTrue(helper.calls.isEmpty)
    }

    func testSecureHelperExecutorBuildsOneBoundedGetRequest() throws {
        let requestBox = LockedValue<SecureSubprocessRequest?>(nil)
        let executor = SecureDockerCredentialHelperExecutor { request, _ in
            requestBox.set(request)
            return SecureSubprocessResult(
                exitStatus: 0,
                terminationSignal: nil,
                standardOutput: Data(#"{"Username":"user","Secret":"secret"}"#.utf8),
                standardError: Data("ignored helper warning".utf8),
                durationMilliseconds: 1,
                standardOutputTruncated: false,
                standardErrorTruncated: false
            )
        }

        _ = try executor.get(
            executableURL: URL(fileURLWithPath: "/trusted/docker-credential-special"),
            helperName: "special",
            registry: DockerRegistryCanonicalKey("registry.example.com"),
            cancellation: SecureSubprocessCancellation()
        )

        let request = try XCTUnwrap(requestBox.value)
        XCTAssertEqual(request.executablePath, "/trusted/docker-credential-special")
        XCTAssertEqual(request.arguments, ["get"])
        XCTAssertEqual(request.environment, SecureSubprocessEnvironment.minimal)
        XCTAssertEqual(request.workingDirectory, "/")
        XCTAssertEqual(request.standardInput, Data("registry.example.com\n".utf8))
        XCTAssertEqual(request.maximumStandardInputBytes, 64 * 1_024)
        XCTAssertEqual(request.maximumStandardOutputBytes, 64 * 1_024)
        XCTAssertEqual(request.maximumStandardErrorBytes, 64 * 1_024)
        XCTAssertEqual(request.timeoutMilliseconds, 10_000)
    }

    func testSecureHelperExecutorMapsCancellationAndCleanupFailuresWithoutStderr() throws {
        let leakedValue = "stderr-secret-value"
        let cancelled = SecureDockerCredentialHelperExecutor { _, _ in
            throw SecureSubprocessError.cancelled(
                SecureSubprocessResult(
                    exitStatus: -1,
                    terminationSignal: nil,
                    standardOutput: Data(),
                    standardError: Data(leakedValue.utf8),
                    durationMilliseconds: 1,
                    standardOutputTruncated: false,
                    standardErrorTruncated: false
                )
            )
        }

        XCTAssertThrowsError(
            try cancelled.get(
                executableURL: URL(fileURLWithPath: "/trusted/docker-credential-special"),
                helperName: "special",
                registry: DockerRegistryCanonicalKey("registry.example.com"),
                cancellation: SecureSubprocessCancellation()
            )
        ) { error in
            XCTAssertEqual(error as? RegistryCredentialLookupError, .cancelled)
            XCTAssertFalse(String(describing: error).contains(leakedValue))
        }

        let cleanupFailure = SecureDockerCredentialHelperExecutor { _, _ in
            throw SecureSubprocessError.processTreeCleanupFailed(
                SecureSubprocessResult(
                    exitStatus: -1,
                    terminationSignal: nil,
                    standardOutput: Data(),
                    standardError: Data(leakedValue.utf8),
                    durationMilliseconds: 1,
                    standardOutputTruncated: false,
                    standardErrorTruncated: false
                )
            )
        }
        XCTAssertThrowsError(
            try cleanupFailure.get(
                executableURL: URL(fileURLWithPath: "/trusted/docker-credential-special"),
                helperName: "special",
                registry: DockerRegistryCanonicalKey("registry.example.com"),
                cancellation: SecureSubprocessCancellation()
            )
        ) { error in
            XCTAssertEqual(error as? RegistryCredentialLookupError, .helperProcessFailed)
            XCTAssertFalse(String(describing: error).contains(leakedValue))
        }
    }

    private func configurationDocument(
        _ object: [String: Any],
        source: RegistryCredentialLookupSource
    ) throws -> DockerCredentialConfigurationDocument {
        DockerCredentialConfigurationDocument(
            data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            source: source
        )
    }

    private func helperOutput(
        serverURL: String,
        username: String,
        secret: String,
        additional: [String: String] = [:]
    ) -> Data {
        var object = additional
        object["ServerURL"] = serverURL
        object["Username"] = username
        object["Secret"] = secret
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private final class RecordingCredentialHelperExecutor:
    DockerCredentialHelperExecuting,
    @unchecked Sendable
{
    struct Call {
        let executableURL: URL
        let helperName: String
        let registry: DockerRegistryCanonicalKey
    }

    private let lock = NSLock()
    private let output: Data
    private var storedCalls: [Call] = []

    init(output: Data) {
        self.output = output
    }

    var calls: [Call] {
        lock.withLock { storedCalls }
    }

    func get(
        executableURL: URL,
        helperName: String,
        registry: DockerRegistryCanonicalKey,
        cancellation: SecureSubprocessCancellation
    ) throws -> Data {
        if cancellation.isCancelled {
            throw RegistryCredentialLookupError.cancelled
        }
        lock.withLock {
            storedCalls.append(
                Call(
                    executableURL: executableURL,
                    helperName: helperName,
                    registry: registry
                )
            )
        }
        return output
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func set(_ value: Value) {
        lock.withLock { storedValue = value }
    }
}

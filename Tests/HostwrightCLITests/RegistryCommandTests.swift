import Foundation
import HostwrightRegistry
import HostwrightSecrets
import XCTest
@testable import HostwrightCLI

final class RegistryCommandTests: XCTestCase {
    func testRegistrySBOMParsersExposeExactCredentialFreeSurface()
        throws
    {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        let confirmation = String(repeating: "c", count: 64)
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "sbom", "generate",
                "/tmp/image.oci",
                "--manifest", "/tmp/hostwright.yml",
                "--service", "api",
                "--server", "registry.example.com",
                "--repository", "team/api",
                "--format", "spdx-json",
                "--state-db", "/tmp/state.sqlite",
                "--json"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .sbom(
                        .generate(
                            archivePath: "/tmp/image.oci",
                            manifestPath: "/tmp/hostwright.yml",
                            serviceName: "api",
                            server: "registry.example.com",
                            repository: "team/api",
                            format: "spdx-json",
                            provenanceDescriptorDigest: nil,
                            provenanceReferrerDigest: nil
                        )
                    ),
                    stateDatabasePath: "/tmp/state.sqlite",
                    output: .json
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "sbom", "resume", discoveryID,
                "--confirm-plan", confirmation,
                "--state-db", "/tmp/state.sqlite",
                "--json"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .sbom(
                        .resume(
                            operationGroupID: discoveryID,
                            confirmationPlanSHA256: confirmation
                        )
                    ),
                    stateDatabasePath: "/tmp/state.sqlite",
                    output: .json
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "sbom", "ingest", discoveryID,
                "--manifest", "/tmp/hostwright.yml",
                "--service", "api"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .sbom(
                        .ingest(
                            discoveryID: discoveryID,
                            manifestPath: "/tmp/hostwright.yml",
                            serviceName: "api"
                        )
                    ),
                    stateDatabasePath: nil,
                    output: .text
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "sbom", "export",
                "/tmp/hostwright.yml",
                "--service", "api",
                "--format", "cyclonedx-json",
                "--output-path", "/tmp/image.cdx.json"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .sbom(
                        .export(
                            manifestPath: "/tmp/hostwright.yml",
                            serviceName: "api",
                            format: "cyclonedx-json",
                            outputPath: "/tmp/image.cdx.json"
                        )
                    ),
                    stateDatabasePath: nil,
                    output: .text
                )
            )
        )

        let rejected = [
            [
                "registry", "sbom", "generate", "relative.oci",
                "--manifest", "/tmp/hostwright.yml",
                "--server", "registry.example.com",
                "--repository", "team/api",
                "--format", "spdx-json"
            ],
            [
                "registry", "sbom", "generate", "/tmp/image.oci",
                "--manifest", "/tmp/hostwright.yml",
                "--server", "registry.example.com",
                "--repository", "team/api",
                "--format", "spdx-json",
                "--provenance-descriptor-digest",
                "sha256:" + String(repeating: "a", count: 64)
            ],
            [
                "registry", "sbom", "ingest", discoveryID,
                "--manifest", "/tmp/hostwright.yml",
                "--token", "secret"
            ],
            [
                "registry", "sbom", "export",
                "/tmp/hostwright.yml",
                "--format", "unknown",
                "--output-path", "/tmp/output"
            ],
            [
                "registry", "sbom", "query",
                "relative-hostwright.yml"
            ],
            [
                "registry", "sbom", "resume", discoveryID,
                "--confirm-plan", "not-a-sha256"
            ]
        ]
        for arguments in rejected {
            XCTAssertThrowsError(
                try CLICommand.parse(arguments: arguments)
            )
        }
    }

    func testRegistryTrustParsersExposeExactCredentialFreeSurface()
        throws
    {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "trust", "verify", discoveryID,
                "--manifest", "/tmp/hostwright.yml",
                "--subject-manifest", "/tmp/subject.json",
                "--cosign", "/opt/homebrew/bin/cosign",
                "--service", "api",
                "--state-db", "/tmp/state.sqlite",
                "--json"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .trust(
                        .verify(
                            discoveryID: discoveryID,
                            manifestPath: "/tmp/hostwright.yml",
                            subjectManifestPath: "/tmp/subject.json",
                            cosignPath: "/opt/homebrew/bin/cosign",
                            serviceName: "api"
                        )
                    ),
                    stateDatabasePath: "/tmp/state.sqlite",
                    output: .json
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "trust", "status",
                "/tmp/hostwright.yml",
                "--service", "api"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .trust(
                        .status(
                            manifestPath: "/tmp/hostwright.yml",
                            serviceName: "api"
                        )
                    ),
                    stateDatabasePath: nil,
                    output: .text
                )
            )
        )

        let rejected = [
            [
                "registry", "trust", "verify", discoveryID,
                "--manifest", "/tmp/hostwright.yml",
                "--subject-manifest", "/tmp/subject.json",
                "--cosign", "/opt/homebrew/bin/cosign",
                "--token", "secret"
            ],
            [
                "registry", "trust", "verify", discoveryID,
                "--manifest", "/tmp/hostwright.yml",
                "--subject-manifest", "relative.json",
                "--cosign", "/opt/homebrew/bin/cosign"
            ],
            [
                "registry", "trust", "revoke-exception",
                discoveryID, "--service", "api"
            ]
        ]
        for arguments in rejected {
            XCTAssertThrowsError(
                try CLICommand.parse(arguments: arguments)
            )
        }
    }

    func testRegistryLoginParsesWithoutCredentialArgument() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry",
                "login",
                "registry.example.com:5443",
                "--username",
                "operator",
                "--state-db",
                "/tmp/hostwright-state.sqlite",
                "--json"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .login(
                        server: "registry.example.com:5443",
                        username: "operator"
                    ),
                    stateDatabasePath: "/tmp/hostwright-state.sqlite",
                    output: .json
                )
            )
        )
    }

    func testRegistryStatusDefaultsRepositoryActionToPull() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry",
                "status",
                "registry.example.com",
                "--repository",
                "team/api",
                "--output",
                "json"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .status(
                        server: "registry.example.com",
                        repository: "team/api",
                        actions: ["pull"]
                    ),
                    stateDatabasePath: nil,
                    output: .json
                )
            )
        )
    }

    func testRegistryStatusSortsExplicitActions() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry",
                "status",
                "registry.example.com",
                "--repository",
                "team/api",
                "--action",
                "push",
                "--action",
                "pull"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .status(
                        server: "registry.example.com",
                        repository: "team/api",
                        actions: ["pull", "push"]
                    ),
                    stateDatabasePath: nil,
                    output: .text
                )
            )
        )
    }

    func testRegistryParserRejectsCredentialArgumentsAndInvalidCombinations() {
        let rejected = [
            ["registry", "login", "registry.example.com", "--username", "user", "--password", "secret"],
            ["registry", "login", "registry.example.com"],
            ["registry", "logout", "registry.example.com", "--username", "user"],
            ["registry", "status", "registry.example.com", "--action", "pull"],
            ["registry", "status", "registry.example.com", "--repository", "team/api", "--action", "delete"],
            ["registry", "status", "registry.example.com", "--repository", "team/api", "--action", "pull", "--action", "pull"],
            ["registry", "status", "registry.example.com", "--state-db", "/tmp/state.sqlite"],
            ["registry", "unknown", "registry.example.com"]
        ]
        for arguments in rejected {
            XCTAssertThrowsError(try CLICommand.parse(arguments: arguments))
        }
    }

    func testReferrerFetchParserUsesExactBoundedFields() throws {
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "referrers", "fetch",
                "registry.example.com",
                "--repository", "team/api",
                "--subject",
                "sha256:" + String(repeating: "a", count: 64),
                "--artifact-type",
                "application/vnd.example.opaque.v1",
                "--offline",
                "--state-db", "/tmp/hostwright-state.sqlite",
                "--json"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .referrers(
                        .fetch(
                            server: "registry.example.com",
                            repository: "team/api",
                            subjectDigest:
                                "sha256:" +
                                String(repeating: "a", count: 64),
                            artifactType:
                                "application/vnd.example.opaque.v1",
                            offline: true
                        )
                    ),
                    stateDatabasePath:
                        "/tmp/hostwright-state.sqlite",
                    output: .json
                )
            )
        )
    }

    func testReferrerMutationParsersRequireExactIdentifiers() throws {
        let discoveryID =
            "11111111-1111-4111-8111-111111111111"
        let groupID =
            "22222222-2222-4222-8222-222222222222"
        let digest =
            "sha256:" + String(repeating: "b", count: 64)
        let confirmation = String(repeating: "c", count: 64)
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "referrers", "publish",
                discoveryID,
                "--target-server", "target.example.com",
                "--target-repository", "team/copy"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .referrers(
                        .publish(
                            discoveryID: discoveryID,
                            targetServer: "target.example.com",
                            targetRepository: "team/copy"
                        )
                    ),
                    stateDatabasePath: nil,
                    output: .text
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "referrers", "prune",
                discoveryID,
                "--digest", digest,
                "--confirm-plan", confirmation,
                "--json"
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .referrers(
                        .prune(
                            discoveryID: discoveryID,
                            referrerDigest: digest,
                            confirmationPlanSHA256: confirmation
                        )
                    ),
                    stateDatabasePath: nil,
                    output: .json
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "registry", "referrers", "resume",
                groupID,
                "--confirm-plan", confirmation
            ]),
            .registry(
                options: RegistryCLIOptions(
                    action: .referrers(
                        .resume(
                            operationGroupID: groupID,
                            confirmationPlanSHA256: confirmation
                        )
                    ),
                    stateDatabasePath: nil,
                    output: .text
                )
            )
        )
    }

    func testReferrerParserRejectsCredentialsAndUnsafeCombinations() {
        let id = "11111111-1111-4111-8111-111111111111"
        let rejected = [
            [
                "registry", "referrers", "fetch",
                "registry.example.com",
                "--repository", "team/api",
                "--subject",
                "sha256:" + String(repeating: "a", count: 64),
                "--password", "secret"
            ],
            [
                "registry", "referrers", "copy",
                "registry.example.com",
                "--repository", "team/api",
                "--subject",
                "sha256:" + String(repeating: "a", count: 64),
                "--target-server", "target.example.com",
                "--target-repository", "team/copy",
                "--offline"
            ],
            [
                "registry", "referrers", "prune", id,
                "--digest", "latest"
            ],
            [
                "registry", "referrers", "release", id,
                "--fencing-token", "not-a-uuid"
            ]
        ]
        for arguments in rejected {
            XCTAssertThrowsError(
                try CLICommand.parse(arguments: arguments)
            )
        }
    }

    func testLoginStatusAndLogoutUseKeychainAndDurableStateWithoutDisclosure() throws {
        let directory = try secureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statePath = directory.appendingPathComponent("state.sqlite").path
        let manager = RegistryTestSecretManager()
        let transport = RegistryTestTransport([
            Self.basicChallenge(),
            Self.registrySuccess(),
            Self.basicChallenge(),
            Self.registrySuccess()
        ])
        var environment = CLIEnvironment.live
        environment.secretManager = { manager }
        environment.readSecretInput = { Data("private-password".utf8) }
        environment.registryTransport = { transport }
        environment.registryCredentialDocuments = { [] }

        let login = HostwrightCLI.run(
            arguments: [
                "registry", "login", "registry.example.com",
                "--username", "private-user",
                "--state-db", statePath,
                "--json"
            ],
            environment: environment
        )
        XCTAssertEqual(login.exitCode, 0, login.standardError)
        XCTAssertTrue(login.standardOutput.contains(#""operation":"login""#))
        XCTAssertFalse(login.standardOutput.contains("private-password"))
        XCTAssertFalse(login.standardOutput.contains("private-user"))

        let status = HostwrightCLI.run(
            arguments: [
                "registry", "status", "registry.example.com",
                "--repository", "team/api",
                "--json"
            ],
            environment: environment
        )
        XCTAssertEqual(status.exitCode, 0, status.standardError)
        XCTAssertTrue(
            status.standardOutput.contains(
                #""credentialSource":"hostwright-keychain""#
            )
        )
        XCTAssertTrue(
            status.standardOutput.contains(
                #""requestedScopes":["repository:team/api:pull"]"#
            )
        )
        XCTAssertFalse(status.standardOutput.contains("private-password"))
        XCTAssertFalse(status.standardOutput.contains("private-user"))

        let stateBytes = try Data(contentsOf: URL(fileURLWithPath: statePath))
        XCTAssertFalse(
            String(decoding: stateBytes, as: UTF8.self)
                .contains("private-password")
        )
        XCTAssertFalse(
            String(decoding: stateBytes, as: UTF8.self)
                .contains("private-user")
        )

        let logout = HostwrightCLI.run(
            arguments: [
                "registry", "logout", "registry.example.com",
                "--state-db", statePath,
                "--json"
            ],
            environment: environment
        )
        XCTAssertEqual(logout.exitCode, 0, logout.standardError)
        XCTAssertTrue(logout.standardOutput.contains("credential-removed"))
        XCTAssertEqual(manager.itemCount, 0)
        XCTAssertEqual(transport.requestCount, 4)
    }

    func testRejectedLoginDoesNotMutateKeychainOrState() throws {
        let directory = try secureTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statePath = directory.appendingPathComponent("state.sqlite").path
        let manager = RegistryTestSecretManager()
        let transport = RegistryTestTransport([
            Self.basicChallenge(),
            RegistryTransportResponse(
                statusCode: 403,
                headers: [:],
                body: Data()
            )
        ])
        var environment = CLIEnvironment.live
        environment.secretManager = { manager }
        environment.readSecretInput = { Data("rejected-password".utf8) }
        environment.registryTransport = { transport }

        let result = HostwrightCLI.run(
            arguments: [
                "registry", "login", "registry.example.com",
                "--username", "developer",
                "--state-db", statePath,
                "--json"
            ],
            environment: environment
        )

        XCTAssertEqual(result.exitCode, 71)
        XCTAssertTrue(result.standardError.contains("HW-REGISTRY-003"))
        XCTAssertFalse(result.standardError.contains("rejected-password"))
        XCTAssertEqual(manager.itemCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: statePath))
    }

    func testStatusUsesGuardedDockerCredentialCompatibility() throws {
        let encoded = Data("docker-user:docker-password".utf8)
            .base64EncodedString()
        let configuration = try JSONSerialization.data(
            withJSONObject: [
                "auths": [
                    "registry.example.com": ["auth": encoded]
                ]
            ],
            options: [.sortedKeys]
        )
        let transport = RegistryTestTransport([
            Self.basicChallenge(),
            Self.registrySuccess()
        ])
        var environment = CLIEnvironment.live
        environment.secretManager = {
            RegistryTestSecretManager(backendUnavailable: true)
        }
        environment.registryTransport = { transport }
        environment.registryCredentialDocuments = {
            [
                DockerCredentialConfigurationDocument(
                    data: configuration,
                    source: .dockerAuthFile
                )
            ]
        }
        environment.registryCredentialHelperResolver = {
            FixedDockerCredentialHelperResolver(executables: [:])
        }

        let result = HostwrightCLI.run(
            arguments: [
                "registry", "status", "registry.example.com", "--json"
            ],
            environment: environment
        )

        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(
            result.standardOutput.contains(
                #""credentialSource":"docker-auth-file""#
            )
        )
        XCTAssertFalse(result.standardOutput.contains("docker-user"))
        XCTAssertFalse(result.standardOutput.contains("docker-password"))
    }

    private static func basicChallenge() -> RegistryTransportResponse {
        RegistryTransportResponse(
            statusCode: 401,
            headers: ["www-authenticate": #"Basic realm="private""#],
            body: Data()
        )
    }

    private static func registrySuccess() -> RegistryTransportResponse {
        RegistryTransportResponse(
            statusCode: 200,
            headers: ["docker-distribution-api-version": "registry/2.0"],
            body: Data()
        )
    }

    private func secureTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-registry-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}

private final class RegistryTestTransport:
    RegistrySynchronousHTTPTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var responses: [RegistryTransportResponse]
    private var requests: [RegistryTransportRequest] = []

    init(_ responses: [RegistryTransportResponse]) {
        self.responses = responses
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        try lock.withLock {
            requests.append(request)
            guard !responses.isEmpty else {
                throw RegistryTransportError.transportFailed
            }
            return responses.removeFirst()
        }
    }
}

private final class RegistryTestSecretManager:
    SecretManager,
    @unchecked Sendable
{
    private struct Item {
        let value: String
        let metadata: SecretMetadata
    }

    private let lock = NSLock()
    private let backendUnavailable: Bool
    private var items: [HostwrightSecretReference: Item] = [:]

    init(backendUnavailable: Bool = false) {
        self.backendUnavailable = backendUnavailable
    }

    var itemCount: Int {
        lock.withLock { items.count }
    }

    func readString(reference: HostwrightSecretReference) throws -> String {
        try lock.withLock {
            try requireBackend()
            guard let item = items[reference] else {
                throw SecretStoreError.notFound("Secret item was not found.")
            }
            return item.value
        }
    }

    func create(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        itemID: UUID
    ) throws -> SecretMetadata {
        try lock.withLock {
            try requireBackend()
            guard items[reference] == nil else {
                throw SecretStoreError.duplicate("Secret item already exists.")
            }
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            let metadata = SecretMetadata(
                reference: reference,
                itemID: itemID,
                version: 1,
                createdAt: timestamp,
                updatedAt: timestamp,
                accessibility: .whenUnlockedThisDeviceOnly,
                synchronizable: false
            )
            items[reference] = Item(
                value: value.dataString(),
                metadata: metadata
            )
            return metadata
        }
    }

    func update(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        expectedItemID: UUID
    ) throws -> SecretMetadata {
        try lock.withLock {
            try requireBackend()
            guard let existing = items[reference],
                  existing.metadata.itemID == expectedItemID else {
                throw SecretStoreError.concurrentMutation(
                    "Secret item changed."
                )
            }
            let metadata = SecretMetadata(
                reference: reference,
                itemID: expectedItemID,
                version: existing.metadata.version + 1,
                createdAt: existing.metadata.createdAt,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
                accessibility: .whenUnlockedThisDeviceOnly,
                synchronizable: false
            )
            items[reference] = Item(
                value: value.dataString(),
                metadata: metadata
            )
            return metadata
        }
    }

    func listMetadata() throws -> [SecretMetadata] {
        try lock.withLock {
            try requireBackend()
            return items.values.map(\.metadata)
        }
    }

    func check(reference: HostwrightSecretReference) throws -> SecretMetadata {
        try lock.withLock {
            try requireBackend()
            guard let item = items[reference] else {
                throw SecretStoreError.notFound("Secret item was not found.")
            }
            return item.metadata
        }
    }

    func delete(
        reference: HostwrightSecretReference,
        expectedItemID: UUID
    ) throws {
        try lock.withLock {
            try requireBackend()
            guard let existing = items[reference],
                  existing.metadata.itemID == expectedItemID else {
                throw SecretStoreError.concurrentMutation(
                    "Secret item changed."
                )
            }
            _ = items.removeValue(forKey: reference)
        }
    }

    private func requireBackend() throws {
        if backendUnavailable {
            throw SecretStoreError.backendUnavailable(
                "Keychain is unavailable."
            )
        }
    }
}

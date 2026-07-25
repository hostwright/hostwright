import Darwin
import Foundation
import XCTest
@testable import HostwrightSecrets

final class SecretProviderTests: XCTestCase {
    func testWorkloadScopeRejectsNonPositiveGeneration() {
        XCTAssertThrowsError(
            try HostwrightSecretWorkloadScope(
                projectID: UUID(),
                resourceID: UUID(),
                generation: 0,
                serviceName: "api"
            )
        )
    }

    func testBuiltInProviderHonorsCancellationBeforeFileAccess() throws {
        let reference = try HostwrightSecretReference.parse(
            "local-file:///private/hostwright-must-not-be-read"
        )
        let request = HostwrightSecretProviderRequest(
            reference: reference,
            workload: try workload(),
            environmentKey: "TOKEN",
            resolutionTime: Date(),
            cancellationCheck: { true }
        )

        XCTAssertThrowsError(
            try HostwrightLocalFileSecretProvider().resolve(request)
        ) { error in
            guard case .cancelled = error as? SecretStoreError else {
                return XCTFail("Expected cancelled, got \(error).")
            }
        }
    }

    func testBuiltInDescriptorsAreStableAndVersioned() {
        let descriptors = [
            HostwrightKeychainSecretProvider(
                manager: FixedSecretManager()
            ).descriptor,
            HostwrightEnvironmentFileSecretProvider().descriptor,
            HostwrightLocalFileSecretProvider().descriptor
        ]

        XCTAssertEqual(
            descriptors.map(\.providerID),
            ["keychain", "env-file", "local-file"]
        )
        XCTAssertTrue(
            descriptors.allSatisfy {
                $0.providerVersion == "1"
                    && $0.capabilities == [.resolve, .versioned]
            }
        )
    }

    func testRegistryRequiresExactWorkloadReferenceAndEnvironmentGrant() throws {
        let fixture = try SecureFileFixture(contents: "scoped-secret")
        defer { fixture.remove() }
        let reference = try HostwrightSecretReference.parse(
            "local-file://\(fixture.path)"
        )
        let scope = try workload(generation: 7)
        let grant = try HostwrightSecretProviderGrant(
            providerID: "local-file",
            reference: reference,
            workload: scope,
            environmentKey: "API_TOKEN"
        )
        let registry = try HostwrightSecretProviderRegistry(
            providers: [HostwrightLocalFileSecretProvider()],
            grants: [grant]
        )

        let result = try registry.resolve(
            reference: reference,
            for: scope,
            environmentKey: "API_TOKEN",
            at: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(result.stringValue(), "scoped-secret")
        XCTAssertFalse(result.metadata.version.isEmpty)

        for attempt in [
            {
                try registry.resolve(
                    reference: reference,
                    for: try self.workload(generation: 8),
                    environmentKey: "API_TOKEN"
                )
            },
            {
                try registry.resolve(
                    reference: reference,
                    for: scope,
                    environmentKey: "OTHER_TOKEN"
                )
            }
        ] {
            XCTAssertThrowsError(try attempt()) { error in
                guard case .permissionDenied(let message) =
                    error as? SecretStoreError else {
                    return XCTFail("Expected permissionDenied, got \(error).")
                }
                XCTAssertFalse(message.contains(fixture.path))
                XCTAssertFalse(message.contains(reference.rawValue))
                XCTAssertFalse(message.contains("scoped-secret"))
            }
        }
    }

    func testRegistryRejectsGrantForDifferentTypedProvider() throws {
        let reference = try HostwrightSecretReference.parse(
            "external://vault/item"
        )
        let grant = try HostwrightSecretProviderGrant(
            providerID: "different-provider",
            reference: reference,
            workload: try workload(),
            environmentKey: "TOKEN"
        )

        XCTAssertThrowsError(
            try HostwrightSecretProviderRegistry(
                providers: [],
                grants: [grant]
            )
        )
    }

    func testGrantActivationAndExpiryFailClosed() throws {
        let fixture = try SecureFileFixture(contents: "bounded")
        defer { fixture.remove() }
        let reference = try HostwrightSecretReference.parse(
            "local-file://\(fixture.path)"
        )
        let scope = try workload()
        let grant = try HostwrightSecretProviderGrant(
            providerID: "local-file",
            reference: reference,
            workload: scope,
            environmentKey: "TOKEN",
            validFrom: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        let registry = try HostwrightSecretProviderRegistry(
            providers: [HostwrightLocalFileSecretProvider()],
            grants: [grant]
        )

        XCTAssertThrowsError(
            try registry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN",
                at: Date(timeIntervalSince1970: 99)
            )
        ) { error in
            guard case .permissionDenied(let message) =
                error as? SecretStoreError else {
                return XCTFail("Expected permissionDenied, got \(error).")
            }
            XCTAssertTrue(message.contains("not active"))
        }
        XCTAssertNoThrow(
            try registry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN",
                at: Date(timeIntervalSince1970: 150)
            )
        )
        XCTAssertThrowsError(
            try registry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN",
                at: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            guard case .permissionDenied(let message) =
                error as? SecretStoreError else {
                return XCTFail("Expected permissionDenied, got \(error).")
            }
            XCTAssertTrue(message.contains("expired"))
        }
    }

    func testEnvironmentFileIsStrictCommandFreeAndRejectsDuplicateKeys() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-provider-marker-\(UUID())")
        let literal = "$(touch \(marker.path))"
        let fixture = try SecureFileFixture(
            contents: "# local secrets\nTOKEN=\(literal)\nEMPTY=\n"
        )
        defer {
            fixture.remove()
            if FileManager.default.fileExists(atPath: marker.path) {
                try? FileManager.default.removeItem(at: marker)
            }
        }
        let reference = try HostwrightSecretReference.parse(
            "env-file://\(fixture.path)#TOKEN"
        )
        let scope = try workload()
        let registry = try registry(
            provider: HostwrightEnvironmentFileSecretProvider(),
            reference: reference,
            scope: scope,
            environmentKey: "TOKEN"
        )

        XCTAssertEqual(
            try registry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN"
            ).stringValue(),
            literal
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        try fixture.replace(contents: "TOKEN=first\nTOKEN=second\n")
        XCTAssertThrowsError(
            try registry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN"
            )
        ) { error in
            guard case .backendUnavailable(let message) =
                error as? SecretStoreError else {
                return XCTFail("Expected backendUnavailable, got \(error).")
            }
            XCTAssertFalse(message.contains(fixture.path))
            XCTAssertFalse(message.contains("first"))
            XCTAssertFalse(message.contains("second"))
        }
    }

    func testGuardedFileProviderRejectsUnsafeModeSymlinkHardLinkAndOversize() throws {
        let insecure = try SecureFileFixture(contents: "mode-secret")
        defer { insecure.remove() }
        XCTAssertEqual(Darwin.chmod(insecure.path, 0o644), 0)
        try assertGuardedReadRejected(insecure)

        let target = try SecureFileFixture(contents: "symlink-secret")
        defer { target.remove() }
        let symlinkPath = target.directory
            .appendingPathComponent("secret-link")
            .path
        XCTAssertEqual(Darwin.symlink(target.path, symlinkPath), 0)
        let symlinkFixture = SecureFileFixture(
            directory: target.directory,
            path: symlinkPath,
            ownsDirectory: false
        )
        try assertGuardedReadRejected(symlinkFixture)

        let hardLink = try SecureFileFixture(contents: "hard-link-secret")
        defer { hardLink.remove() }
        let hardLinkPath = hardLink.directory
            .appendingPathComponent("secret-hard-link")
            .path
        XCTAssertEqual(Darwin.link(hardLink.path, hardLinkPath), 0)
        try assertGuardedReadRejected(hardLink)

        let oversized = try SecureFileFixture(
            data: Data(
                repeating: 0x61,
                count: HostwrightSecretValue.maximumByteCount + 1
            )
        )
        defer { oversized.remove() }
        let reference = try HostwrightSecretReference.parse(
            "local-file://\(oversized.path)"
        )
        let scope = try workload()
        let registry = try self.registry(
            provider: HostwrightLocalFileSecretProvider(),
            reference: reference,
            scope: scope,
            environmentKey: "TOKEN"
        )
        XCTAssertThrowsError(
            try registry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN"
            )
        ) { error in
            guard case .invalidValue(let message) =
                error as? SecretStoreError else {
                return XCTFail("Expected invalidValue, got \(error).")
            }
            XCTAssertFalse(message.contains(oversized.path))
        }
    }

    func testExternalAndPluginRegistrationRouteByTypedAuthority() throws {
        for kind in [
            HostwrightSecretProviderKind.external,
            HostwrightSecretProviderKind.plugin
        ] {
            let providerID = kind == .external ? "vault" : "signed-provider"
            let reference = try HostwrightSecretReference.parse(
                "\(kind.rawValue)://\(providerID)/api-token"
            )
            let scope = try workload()
            let provider = try StaticSecretProvider(
                providerID: providerID,
                kind: kind,
                value: "registered-value"
            )
            let registry = try self.registry(
                provider: provider,
                reference: reference,
                scope: scope,
                environmentKey: "TOKEN"
            )

            let result = try registry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN",
                at: Date(timeIntervalSince1970: 100)
            )
            XCTAssertEqual(result.stringValue(), "registered-value")
            XCTAssertEqual(result.metadata.providerID, providerID)
            XCTAssertEqual(result.metadata.providerKind, kind)
        }
    }

    func testMissingProviderAndProviderErrorsRemainRedacted() throws {
        let scope = try workload()
        let reference = try HostwrightSecretReference.parse(
            "external://vault/sensitive-item"
        )
        let grant = try HostwrightSecretProviderGrant(
            providerID: "vault",
            reference: reference,
            workload: scope,
            environmentKey: "TOKEN"
        )
        let missingRegistry = try HostwrightSecretProviderRegistry(
            providers: [],
            grants: [grant]
        )
        XCTAssertThrowsError(
            try missingRegistry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN"
            )
        ) { error in
            let message = String(describing: error)
            XCTAssertFalse(message.contains(reference.rawValue))
            XCTAssertFalse(message.contains("sensitive-item"))
        }

        let leakingProvider = try ThrowingSecretProvider(
            providerID: "vault",
            kind: .external,
            error: .backendUnavailable(
                "leaked-value at /private/sensitive/path for \(reference.rawValue)"
            )
        )
        let leakingRegistry = try HostwrightSecretProviderRegistry(
            providers: [leakingProvider],
            grants: [grant]
        )
        XCTAssertThrowsError(
            try leakingRegistry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN"
            )
        ) { error in
            let message = String(describing: error)
            XCTAssertFalse(message.contains("leaked-value"))
            XCTAssertFalse(message.contains("/private/sensitive/path"))
            XCTAssertFalse(message.contains(reference.rawValue))
        }
    }

    func testRegistryBlocksStaleRefreshAndExpiredProviderResults() throws {
        let scope = try workload()
        let reference = try HostwrightSecretReference.parse(
            "external://vault/item"
        )
        let grant = try HostwrightSecretProviderGrant(
            providerID: "vault",
            reference: reference,
            workload: scope,
            environmentKey: "TOKEN"
        )
        let observedAt = Date(timeIntervalSince1970: 100)

        let staleProvider = try StaticSecretProvider(
            providerID: "vault",
            kind: .external,
            value: "stale",
            capabilities: [.resolve, .versioned, .refresh],
            observedAt: observedAt,
            refreshAfter: Date(timeIntervalSince1970: 150)
        )
        let staleRegistry = try HostwrightSecretProviderRegistry(
            providers: [staleProvider],
            grants: [grant]
        )
        XCTAssertThrowsError(
            try staleRegistry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN",
                at: Date(timeIntervalSince1970: 150)
            )
        ) { error in
            guard case .backendUnavailable(let message) =
                error as? SecretStoreError else {
                return XCTFail("Expected backendUnavailable, got \(error).")
            }
            XCTAssertTrue(message.contains("requires refresh"))
        }

        let expiredProvider = try StaticSecretProvider(
            providerID: "vault",
            kind: .external,
            value: "expired",
            capabilities: [.resolve, .versioned, .expiring],
            observedAt: observedAt,
            expiresAt: Date(timeIntervalSince1970: 150)
        )
        let expiredRegistry = try HostwrightSecretProviderRegistry(
            providers: [expiredProvider],
            grants: [grant]
        )
        XCTAssertThrowsError(
            try expiredRegistry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN",
                at: Date(timeIntervalSince1970: 150)
            )
        ) { error in
            guard case .backendUnavailable(let message) =
                error as? SecretStoreError else {
                return XCTFail("Expected backendUnavailable, got \(error).")
            }
            XCTAssertTrue(message.contains("expired"))
        }
    }

    func testKeychainProviderReturnsExactManagedVersion() throws {
        let reference = try HostwrightSecretReference.parse(
            "keychain://hostwright.test/token"
        )
        let metadata = SecretMetadata(
            reference: reference,
            itemID: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
            version: 4,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            accessibility: .whenUnlockedThisDeviceOnly,
            synchronizable: false
        )
        let manager = FixedSecretManager(
            value: "managed-value",
            metadata: metadata
        )
        let scope = try workload()
        let registry = try self.registry(
            provider: HostwrightKeychainSecretProvider(manager: manager),
            reference: reference,
            scope: scope,
            environmentKey: "TOKEN"
        )

        let result = try registry.resolve(
            reference: reference,
            for: scope,
            environmentKey: "TOKEN",
            at: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(result.stringValue(), "managed-value")
        XCTAssertEqual(
            result.metadata.version,
            "12345678-1234-1234-1234-123456789abc:4"
        )
    }

    private func workload(
        generation: Int = 1
    ) throws -> HostwrightSecretWorkloadScope {
        try HostwrightSecretWorkloadScope(
            projectID: UUID(
                uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            )!,
            resourceID: UUID(
                uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            )!,
            generation: generation,
            serviceName: "api"
        )
    }

    private func registry(
        provider: any HostwrightSecretProvider,
        reference: HostwrightSecretReference,
        scope: HostwrightSecretWorkloadScope,
        environmentKey: String
    ) throws -> HostwrightSecretProviderRegistry {
        try HostwrightSecretProviderRegistry(
            providers: [provider],
            grants: [
                try HostwrightSecretProviderGrant(
                    providerID: provider.descriptor.providerID,
                    reference: reference,
                    workload: scope,
                    environmentKey: environmentKey
                )
            ]
        )
    }

    private func assertGuardedReadRejected(
        _ fixture: SecureFileFixture
    ) throws {
        let reference = try HostwrightSecretReference.parse(
            "local-file://\(fixture.path)"
        )
        let scope = try workload()
        let registry = try self.registry(
            provider: HostwrightLocalFileSecretProvider(),
            reference: reference,
            scope: scope,
            environmentKey: "TOKEN"
        )
        XCTAssertThrowsError(
            try registry.resolve(
                reference: reference,
                for: scope,
                environmentKey: "TOKEN"
            )
        ) { error in
            let message = String(describing: error)
            XCTAssertFalse(message.contains(fixture.path))
            XCTAssertFalse(message.contains(reference.rawValue))
        }
    }
}

private struct SecureFileFixture {
    let directory: URL
    let path: String
    let ownsDirectory: Bool

    init(contents: String) throws {
        try self.init(data: Data(contents.utf8))
    }

    init(data: Data) throws {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".hostwright-secret-provider-\(UUID())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let file = base.appendingPathComponent("secret", isDirectory: false)
        try data.write(to: file, options: .withoutOverwriting)
        guard Darwin.chmod(file.path, 0o600) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        self.directory = base
        self.path = file.path
        self.ownsDirectory = true
    }

    init(directory: URL, path: String, ownsDirectory: Bool) {
        self.directory = directory
        self.path = path
        self.ownsDirectory = ownsDirectory
    }

    func replace(contents: String) throws {
        guard Darwin.unlink(path) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        try Data(contents.utf8).write(
            to: URL(fileURLWithPath: path),
            options: .withoutOverwriting
        )
        guard Darwin.chmod(path, 0o600) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
    }

    func remove() {
        if ownsDirectory {
            try? FileManager.default.removeItem(at: directory)
        } else {
            _ = Darwin.unlink(path)
        }
    }
}

private struct StaticSecretProvider: HostwrightSecretProvider {
    let descriptor: HostwrightSecretProviderDescriptor
    let value: HostwrightSecretValue
    let observedAt: Date
    let refreshAfter: Date?
    let expiresAt: Date?

    init(
        providerID: String,
        kind: HostwrightSecretProviderKind,
        value: String,
        capabilities: Set<HostwrightSecretProviderCapability> = [
            .resolve,
            .versioned
        ],
        observedAt: Date = Date(timeIntervalSince1970: 100),
        refreshAfter: Date? = nil,
        expiresAt: Date? = nil
    ) throws {
        descriptor = try HostwrightSecretProviderDescriptor(
            providerID: providerID,
            providerVersion: "test-1",
            kind: kind,
            capabilities: capabilities
        )
        self.value = try HostwrightSecretValue(value)
        self.observedAt = observedAt
        self.refreshAfter = refreshAfter
        self.expiresAt = expiresAt
    }

    func resolve(
        _ request: HostwrightSecretProviderRequest
    ) throws -> HostwrightSecretResolution {
        HostwrightSecretResolution(
            value: value,
            metadata: try HostwrightSecretResolutionMetadata(
                providerID: descriptor.providerID,
                providerKind: descriptor.kind,
                version: "static-1",
                observedAt: observedAt,
                refreshAfter: refreshAfter,
                expiresAt: expiresAt
            )
        )
    }
}

private struct ThrowingSecretProvider: HostwrightSecretProvider {
    let descriptor: HostwrightSecretProviderDescriptor
    let error: SecretStoreError

    init(
        providerID: String,
        kind: HostwrightSecretProviderKind,
        error: SecretStoreError
    ) throws {
        descriptor = try HostwrightSecretProviderDescriptor(
            providerID: providerID,
            providerVersion: "test-1",
            kind: kind,
            capabilities: [.resolve]
        )
        self.error = error
    }

    func resolve(
        _ request: HostwrightSecretProviderRequest
    ) throws -> HostwrightSecretResolution {
        throw error
    }
}

private struct FixedSecretManager: SecretManager {
    let value: String
    let metadata: SecretMetadata?

    init(
        value: String = "",
        metadata: SecretMetadata? = nil
    ) {
        self.value = value
        self.metadata = metadata
    }

    func readString(
        reference: HostwrightSecretReference
    ) throws -> String {
        value
    }

    func create(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        itemID: UUID
    ) throws -> SecretMetadata {
        throw SecretStoreError.backendUnavailable("not used")
    }

    func update(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        expectedItemID: UUID
    ) throws -> SecretMetadata {
        throw SecretStoreError.backendUnavailable("not used")
    }

    func listMetadata() throws -> [SecretMetadata] {
        metadata.map { [$0] } ?? []
    }

    func check(
        reference: HostwrightSecretReference
    ) throws -> SecretMetadata {
        guard let metadata else {
            throw SecretStoreError.notFound("not configured")
        }
        return metadata
    }

    func delete(
        reference: HostwrightSecretReference,
        expectedItemID: UUID
    ) throws {
        throw SecretStoreError.backendUnavailable("not used")
    }
}

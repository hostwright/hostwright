import CryptoKit
import Darwin
import Foundation
import HostwrightNetworkProviders
import Security

public struct NetworkHelperProviderInvocation:
    Codable,
    Equatable,
    Sendable
{
    public let declaration: Data
    public let detachedCMS: Data
    public let module: Data
    public let grant: NetworkProviderGrant
    public let operation: NetworkProviderOperation
    public let payload: [String: String]
    public let longRunning: Bool

    public init(
        declaration: Data,
        detachedCMS: Data,
        module: Data,
        grant: NetworkProviderGrant,
        operation: NetworkProviderOperation,
        payload: [String: String] = [:],
        longRunning: Bool = false
    ) {
        self.declaration = declaration
        self.detachedCMS = detachedCMS
        self.module = module
        self.grant = grant
        self.operation = operation
        self.payload = payload
        self.longRunning = longRunning
    }

    private enum CodingKeys: String, CodingKey {
        case declaration
        case detachedCMS
        case module
        case grant
        case operation
        case payload
        case longRunning
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        declaration = try values.decode(
            Data.self,
            forKey: .declaration
        )
        detachedCMS = try values.decode(
            Data.self,
            forKey: .detachedCMS
        )
        module = try values.decode(Data.self, forKey: .module)
        let grant = try values.decode(
            NetworkHelperProviderGrantWire.self,
            forKey: .grant
        )
        guard grant.allowedHTTPSOrigins ==
                grant.allowedHTTPSOrigins.sorted(),
              grant.secretReferences ==
                grant.secretReferences.sorted(),
              grant.identityScopes == grant.identityScopes.sorted(),
              grant.routeScopes == grant.routeScopes.sorted(),
              Set(grant.allowedHTTPSOrigins).count ==
                grant.allowedHTTPSOrigins.count,
              Set(grant.secretReferences).count ==
                grant.secretReferences.count,
              Set(grant.identityScopes).count ==
                grant.identityScopes.count,
              Set(grant.routeScopes).count ==
                grant.routeScopes.count else {
            throw NetworkHelperError.invalidProvider
        }
        self.grant = grant.value
        operation = try values.decode(
            NetworkProviderOperation.self,
            forKey: .operation
        )
        payload = try values.decode(
            [String: String].self,
            forKey: .payload
        )
        longRunning = try values.decode(
            Bool.self,
            forKey: .longRunning
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(declaration, forKey: .declaration)
        try values.encode(detachedCMS, forKey: .detachedCMS)
        try values.encode(module, forKey: .module)
        try values.encode(
            NetworkHelperProviderGrantWire(grant),
            forKey: .grant
        )
        try values.encode(operation, forKey: .operation)
        try values.encode(payload, forKey: .payload)
        try values.encode(longRunning, forKey: .longRunning)
    }

    func validated() throws -> Self {
        guard !declaration.isEmpty,
              declaration.count
                <= RestrictedNetworkProviderHost.maximumDeclarationBytes,
              !detachedCMS.isEmpty,
              detachedCMS.count <= 4 * 1_024 * 1_024,
              !module.isEmpty,
              module.count <= WasmKitNetworkProviderExecutor.maximumModuleBytes
        else {
            throw NetworkHelperError.invalidProvider
        }
        return self
    }
}

private struct NetworkHelperProviderGrantWire: Codable {
    let identifier: String
    let kind: NetworkProviderKind
    let moduleSHA256: String
    let signer: String
    let allowedHTTPSOrigins: [String]
    let secretReferences: [String]
    let identityScopes: [String]
    let routeScopes: [String]
    let approvedBy: String
    let expiresAt: Date

    init(_ value: NetworkProviderGrant) {
        identifier = value.identifier
        kind = value.kind
        moduleSHA256 = value.moduleSHA256
        signer = value.signer
        allowedHTTPSOrigins = value.allowedHTTPSOrigins.sorted()
        secretReferences = value.secretReferences.sorted()
        identityScopes = value.identityScopes.sorted()
        routeScopes = value.routeScopes.sorted()
        approvedBy = value.approvedBy
        expiresAt = value.expiresAt
    }

    var value: NetworkProviderGrant {
        NetworkProviderGrant(
            identifier: identifier,
            kind: kind,
            moduleSHA256: moduleSHA256,
            signer: signer,
            allowedHTTPSOrigins: Set(allowedHTTPSOrigins),
            secretReferences: Set(secretReferences),
            identityScopes: Set(identityScopes),
            routeScopes: Set(routeScopes),
            approvedBy: approvedBy,
            expiresAt: expiresAt
        )
    }
}

public struct NetworkHelperProviderRevocation:
    Codable,
    Equatable,
    Sendable
{
    public let identifier: String
    public let moduleSHA256: String

    public init(identifier: String, moduleSHA256: String) {
        self.identifier = identifier
        self.moduleSHA256 = moduleSHA256
    }

    func validated() throws -> Self {
        guard identifier.range(
            of: "^[a-z0-9](?:[a-z0-9.-]{0,126}[a-z0-9])?$",
            options: .regularExpression
        ) != nil,
        !identifier.contains(".."),
        moduleSHA256.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil else {
            throw NetworkHelperError.invalidProvider
        }
        return self
    }
}

public struct NetworkHelperProviderResult:
    Codable,
    Equatable,
    Sendable
{
    public let payload: [String: String]

    public init(payload: [String: String]) {
        self.payload = payload
    }
}

private struct NetworkHelperProviderAuthority:
    Codable,
    Equatable,
    Sendable
{
    let identifier: String
    let moduleSHA256: String
    let signer: String
    let kind: NetworkProviderKind
    let identity: NetworkHelperDNSIdentity
    let activatedAt: Date
}

private struct NetworkHelperProviderAuthorityV1:
    Codable,
    Equatable,
    Sendable
{
    let identifier: String
    let moduleSHA256: String
    let kind: NetworkProviderKind
    let identity: NetworkHelperDNSIdentity
    let activatedAt: Date
}

private struct NetworkHelperProviderStateV1:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    let authorities: [NetworkHelperProviderAuthorityV1]
}

private struct NetworkHelperProviderState:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    var authorities: [NetworkHelperProviderAuthority]

    init(
        authorities: [NetworkHelperProviderAuthority] = []
    ) {
        schemaVersion = 2
        self.authorities = authorities
    }
}

private struct NetworkHelperProviderLoadedState {
    let state: NetworkHelperProviderState
    let requiresPersistence: Bool
}

actor NetworkHelperProviderStateStore: NetworkProviderRevocationStore {
    static let maximumStateBytes = 1 * 1_024 * 1_024
    static let maximumAuthorities = 512

    private let rootURL: URL
    private let stateURL: URL
    private let owner: uid_t
    private let revocations: FileBackedNetworkProviderRevocationStore
    private var state: NetworkHelperProviderState

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        stateURL = rootURL.appendingPathComponent(
            "authority.json",
            isDirectory: false
        )
        owner = geteuid()
        try Self.prepareDirectory(rootURL, owner: owner)
        revocations = try FileBackedNetworkProviderRevocationStore(
            directoryURL: rootURL.appendingPathComponent(
                "revocations",
                isDirectory: true
            )
        )
        try Self.removeInterruptedWrites(rootURL, owner: owner)
        let loaded = try Self.loadState(
            from: stateURL,
            owner: owner
        )
        state = loaded?.state ?? NetworkHelperProviderState()
        try Self.validate(state)
        if loaded?.requiresPersistence == true {
            try Self.write(
                state,
                stateURL: stateURL,
                rootURL: rootURL,
                owner: owner
            )
        }
    }

    func isRevoked(
        identifier: String,
        moduleSHA256: String
    ) async throws -> Bool {
        try await revocations.isRevoked(
            identifier: identifier,
            moduleSHA256: moduleSHA256
        )
    }

    func revoke(
        identifier: String,
        moduleSHA256: String,
        at: Date
    ) async throws {
        try await revocations.revoke(
            identifier: identifier,
            moduleSHA256: moduleSHA256,
            at: at
        )
    }

    func recoverRevokedAuthorities() async throws {
        var retained: [NetworkHelperProviderAuthority] = []
        for authority in state.authorities {
            if try await revocations.isRevoked(
                identifier: authority.identifier,
                moduleSHA256: authority.moduleSHA256
            ) {
                continue
            }
            retained.append(authority)
        }
        guard retained != state.authorities else {
            return
        }
        state.authorities = retained
        try persist()
    }

    func activate(
        declaration: NetworkProviderDeclaration,
        identity: NetworkHelperDNSIdentity,
        at: Date
    ) throws {
        let authority = NetworkHelperProviderAuthority(
            identifier: declaration.identifier,
            moduleSHA256: declaration.moduleSHA256,
            signer: declaration.signer,
            kind: declaration.kind,
            identity: identity,
            activatedAt: at
        )
        state.authorities.removeAll {
            $0.identifier == declaration.identifier
        }
        guard state.authorities.count < Self.maximumAuthorities else {
            throw NetworkProviderError.executionFailed
        }
        state.authorities.append(authority)
        state.authorities.sort {
            ($0.identifier, $0.moduleSHA256) <
                ($1.identifier, $1.moduleSHA256)
        }
        try persist()
    }

    func deactivate(
        identifier: String,
        moduleSHA256: String
    ) throws {
        state.authorities.removeAll {
            $0.identifier == identifier &&
                $0.moduleSHA256 == moduleSHA256
        }
        try persist()
    }

    func hasAuthority(
        identifier: String,
        moduleSHA256: String
    ) -> Bool {
        state.authorities.contains {
            $0.identifier == identifier &&
                $0.moduleSHA256 == moduleSHA256
        }
    }

    func hasAuthority(
        declaration: NetworkProviderDeclaration,
        identity: NetworkHelperDNSIdentity
    ) -> Bool {
        state.authorities.contains {
            $0.identifier == declaration.identifier &&
                $0.moduleSHA256 == declaration.moduleSHA256 &&
                $0.signer == declaration.signer &&
                $0.kind == declaration.kind &&
                $0.identity == identity
        }
    }

    func hasAnyAuthority() -> Bool {
        !state.authorities.isEmpty
    }

    private func persist() throws {
        try Self.write(
            state,
            stateURL: stateURL,
            rootURL: rootURL,
            owner: owner
        )
    }

    private static func validate(
        _ state: NetworkHelperProviderState
    ) throws {
        guard state.schemaVersion == 2,
              state.authorities.count <= maximumAuthorities,
              state.authorities == state.authorities.sorted(by: {
                  ($0.identifier, $0.moduleSHA256) <
                      ($1.identifier, $1.moduleSHA256)
              }),
              Set(state.authorities.map {
                  key($0.identifier, $0.moduleSHA256)
              }).count == state.authorities.count,
              state.authorities.allSatisfy({
                  (try? $0.identity.validated()) != nil
              }),
              state.authorities.allSatisfy({
                  validIdentifier($0.identifier) &&
                      validSHA256($0.moduleSHA256) &&
                      validSigner($0.signer)
              })
        else {
            throw NetworkProviderError.executionFailed
        }
    }

    private static func validate(
        _ state: NetworkHelperProviderStateV1
    ) throws {
        guard state.schemaVersion == 1,
              state.authorities.count <= maximumAuthorities,
              state.authorities == state.authorities.sorted(by: {
                  ($0.identifier, $0.moduleSHA256) <
                      ($1.identifier, $1.moduleSHA256)
              }),
              Set(state.authorities.map {
                  key($0.identifier, $0.moduleSHA256)
              }).count == state.authorities.count,
              state.authorities.allSatisfy({
                  (try? $0.identity.validated()) != nil
              }),
              state.authorities.allSatisfy({
                  validIdentifier($0.identifier) &&
                      validSHA256($0.moduleSHA256)
              })
        else {
            throw NetworkProviderError.executionFailed
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(
            of: "^[a-z0-9](?:[a-z0-9.-]{0,126}[a-z0-9])?$",
            options: .regularExpression
        ) != nil && !value.contains("..")
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }

    private static func validSigner(_ value: String) -> Bool {
        value.utf8.count <= 128 &&
            value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$",
                options: .regularExpression
            ) != nil &&
            !value.contains("..")
    }

    private static func key(
        _ identifier: String,
        _ moduleSHA256: String
    ) -> String {
        "\(identifier):\(moduleSHA256)"
    }

    private static func prepareDirectory(
        _ url: URL,
        owner: uid_t
    ) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw NetworkProviderError.executionFailed
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == owner,
              metadata.st_mode & mode_t(0o7777) == 0o700 else {
            throw NetworkProviderError.executionFailed
        }
    }

    private static func removeInterruptedWrites(
        _ rootURL: URL,
        owner: uid_t
    ) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        for entry in contents where
            entry.lastPathComponent.hasPrefix(".authority-") {
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == owner,
                  metadata.st_nlink == 1,
                  metadata.st_mode & mode_t(0o7777) == 0o600,
                  unlink(entry.path) == 0 else {
                throw NetworkProviderError.executionFailed
            }
        }
    }

    private static func loadState(
        from url: URL,
        owner: uid_t
    ) throws -> NetworkHelperProviderLoadedState? {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw NetworkProviderError.executionFailed
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == owner,
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o7777) == 0o600,
              metadata.st_size > 0,
              metadata.st_size <= off_t(maximumStateBytes) else {
            throw NetworkProviderError.executionFailed
        }
        var data = Data(count: Int(metadata.st_size))
        let count = try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw NetworkProviderError.executionFailed
                }
                offset += count
            }
            return offset
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard count == data.count else {
            throw NetworkProviderError.executionFailed
        }
        if let legacy = try? decoder.decode(
            NetworkHelperProviderStateV1.self,
            from: data
        ), legacy.schemaVersion == 1,
           (try? canonical(legacy)) == data {
            try validate(legacy)
            return NetworkHelperProviderLoadedState(
                state: NetworkHelperProviderState(),
                requiresPersistence: true
            )
        }
        guard let value = try? decoder.decode(
            NetworkHelperProviderState.self,
            from: data
        ), value.schemaVersion == 2,
           (try? canonical(value)) == data else {
            throw NetworkProviderError.executionFailed
        }
        return NetworkHelperProviderLoadedState(
            state: value,
            requiresPersistence: false
        )
    }

    private static func write(
        _ state: NetworkHelperProviderState,
        stateURL: URL,
        rootURL: URL,
        owner: uid_t
    ) throws {
        try validate(state)
        let data = try canonical(state)
        guard data.count <= maximumStateBytes else {
            throw NetworkProviderError.executionFailed
        }
        let temporary = rootURL.appendingPathComponent(
            ".authority-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw NetworkProviderError.executionFailed
        }
        var retainedError: Error?
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0, errno == EINTR {
                        continue
                    }
                    guard written > 0 else {
                        throw NetworkProviderError.executionFailed
                    }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else {
                throw NetworkProviderError.executionFailed
            }
        } catch {
            retainedError = error
        }
        guard close(descriptor) == 0, retainedError == nil else {
            _ = unlink(temporary.path)
            throw retainedError ?? NetworkProviderError.executionFailed
        }
        guard rename(temporary.path, stateURL.path) == 0 else {
            _ = unlink(temporary.path)
            throw NetworkProviderError.executionFailed
        }
        let directory = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw NetworkProviderError.executionFailed
        }
        defer { close(directory) }
        guard fsync(directory) == 0 else {
            throw NetworkProviderError.executionFailed
        }
        _ = owner
    }

    private static func canonical<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct NetworkHelperProviderWasmExecutor:
    NetworkProviderWasmExecutor
{
    func execute(
        module: Data,
        stdin: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data {
        try await WasmKitNetworkProviderExecutor().execute(
            module: module,
            stdin: stdin,
            sandbox: sandbox
        )
    }
}

enum NetworkHelperProviderTrustStore {
    static let directoryName = "trusted-signers"
    static let maximumCertificates = 64
    static let maximumCertificateBytes = 64 * 1_024
    static let maximumTotalBytes = 1 * 1_024 * 1_024

    static func load(
        stateRootURL: URL,
        owner: uid_t = geteuid()
    ) throws -> [Data] {
        let directoryURL = stateRootURL.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        try prepareDirectory(directoryURL, owner: owner)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        guard entries.count <= maximumCertificates else {
            throw NetworkProviderError.executionFailed
        }

        var totalBytes = 0
        var certificates: [Data] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.range(
                of: "^[a-f0-9]{64}\\.der$",
                options: .regularExpression
            ) != nil else {
                throw NetworkProviderError.executionFailed
            }
            let certificate = try readCertificate(
                entry,
                owner: owner
            )
            totalBytes += certificate.count
            guard totalBytes <= maximumTotalBytes,
                  SHA256.hash(data: certificate)
                    .map({ String(format: "%02x", $0) })
                    .joined() == String(name.dropLast(4)),
                  SecCertificateCreateWithData(
                      nil,
                      certificate as CFData
                  ) != nil else {
                throw NetworkProviderError.executionFailed
            }
            certificates.append(certificate)
        }
        return certificates
    }

    private static func prepareDirectory(
        _ url: URL,
        owner: uid_t
    ) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw NetworkProviderError.executionFailed
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == owner,
              metadata.st_mode & mode_t(0o7777) == 0o700 else {
            throw NetworkProviderError.executionFailed
        }
    }

    private static func readCertificate(
        _ url: URL,
        owner: uid_t
    ) throws -> Data {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw NetworkProviderError.executionFailed
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == owner,
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o7777) == 0o600,
              metadata.st_size > 0,
              metadata.st_size <= off_t(maximumCertificateBytes) else {
            throw NetworkProviderError.executionFailed
        }

        var data = Data(count: Int(metadata.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw NetworkProviderError.executionFailed
                }
                offset += count
            }
        }
        guard offset == data.count else {
            throw NetworkProviderError.executionFailed
        }
        return data
    }
}

final class NetworkHelperProviderCoordinator: @unchecked Sendable {
    private let host: RestrictedNetworkProviderHost
    private let state: NetworkHelperProviderStateStore

    init(
        stateRootURL: URL,
        verifier: (any DetachedCMSVerifier)? = nil,
        executor: (any NetworkProviderWasmExecutor)? = nil,
        broker: (any NetworkProviderBroker)? = nil
    ) throws {
        let state = try NetworkHelperProviderStateStore(
            rootURL: stateRootURL
        )
        try Self.awaitResult {
            try await state.recoverRevokedAuthorities()
        }
        self.state = state
        let executor = executor ??
            NetworkHelperProviderWasmExecutor()
        let verifier = try verifier ??
            SecurityDetachedCMSVerifier(
                trustedCertificateDER:
                    NetworkHelperProviderTrustStore.load(
                        stateRootURL: stateRootURL
                    )
            )
        host = RestrictedNetworkProviderHost(
            verifier: verifier,
            executor: executor,
            revocations: state,
            broker: broker ?? Self.productionBroker()
        )
    }

    func invoke(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperProviderInvocation
    ) throws -> NetworkHelperProviderResult {
        let identity = try identity.validated()
        let request = try request.validated()
        let declaration = try decodedDeclaration(request.declaration)
        if request.operation != .setup {
            let hasAuthority = try awaitResult {
                await self.state.hasAuthority(
                    declaration: declaration,
                    identity: identity
                )
            }
            guard hasAuthority else {
                throw NetworkProviderError.deniedGrant
            }
        }
        let result = try awaitResult {
            try await self.host.invoke(
                declaration: request.declaration,
                detachedCMS: request.detachedCMS,
                module: request.module,
                grant: request.grant,
                operation: request.operation,
                payload: request.payload,
                longRunning: request.longRunning
            )
        }
        switch request.operation {
        case .setup:
            try awaitResult {
                try await self.state.activate(
                    declaration: declaration,
                    identity: identity,
                    at: .now
                )
            }
        case .teardown:
            try awaitResult {
                try await self.state.deactivate(
                    identifier: declaration.identifier,
                    moduleSHA256: declaration.moduleSHA256
                )
            }
        case .status, .routes, .identity, .renewal, .reconnect, .drain:
            break
        }
        return NetworkHelperProviderResult(payload: result)
    }

    func revoke(
        identity: NetworkHelperDNSIdentity,
        request: NetworkHelperProviderRevocation
    ) throws -> NetworkHelperProviderResult {
        _ = try identity.validated()
        let request = try request.validated()
        try awaitResult {
            try await self.host.revokeThenStop(
                identifier: request.identifier,
                moduleSHA256: request.moduleSHA256
            ) {
                try await self.state.deactivate(
                    identifier: request.identifier,
                    moduleSHA256: request.moduleSHA256
                )
            }
        }
        return NetworkHelperProviderResult(payload: [:])
    }

    func hasAuthority(
        identifier: String,
        moduleSHA256: String
    ) throws -> Bool {
        try awaitResult {
            await self.state.hasAuthority(
                identifier: identifier,
                moduleSHA256: moduleSHA256
            )
        }
    }

    var hasActiveAuthorities: Bool {
        (try? awaitResult {
            await self.state.hasAnyAuthority()
        }) ?? false
    }

    private func decodedDeclaration(
        _ data: Data
    ) throws -> NetworkProviderDeclaration {
        guard let declaration = try? JSONDecoder().decode(
            NetworkProviderDeclaration.self,
            from: data
        ) else {
            throw NetworkHelperError.invalidProvider
        }
        return declaration
    }

    private func awaitResult<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        try Self.awaitResult(operation)
    }

    private static func awaitResult<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let box = NetworkHelperProviderResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.load().get()
    }

    private static func productionBroker()
        -> URLSessionNetworkProviderBroker
    {
        URLSessionNetworkProviderBroker(
            secretReferenceResolver: { reference in
                let identifier = SHA256.hash(
                    data: Data(reference.utf8)
                )
                .map { String(format: "%02x", $0) }
                .joined()
                return NetworkProviderSecretHandle(
                    identifier: "reference-\(identifier)"
                )
            },
            identityHandler: { _, _ in
                throw NetworkProviderError.deniedGrant
            },
            routeHandler: { _, _ in
                throw NetworkProviderError.deniedGrant
            }
        )
    }
}

private final class NetworkHelperProviderResultBox<Value: Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.withLock {
            precondition(self.result == nil)
            self.result = result
        }
    }

    func load() -> Result<Value, Error> {
        lock.withLock {
            precondition(result != nil)
            return result!
        }
    }
}

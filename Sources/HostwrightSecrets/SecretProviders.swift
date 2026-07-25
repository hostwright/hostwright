import Darwin
import Foundation

public enum HostwrightSecretProviderCapability: String, CaseIterable, Hashable, Sendable {
    case resolve
    case versioned
    case refresh
    case expiring
}

public struct HostwrightSecretProviderDescriptor: Equatable, Sendable {
    public let providerID: String
    public let providerVersion: String
    public let kind: HostwrightSecretProviderKind
    public let capabilities: Set<HostwrightSecretProviderCapability>

    public init(
        providerID: String,
        providerVersion: String = "1",
        kind: HostwrightSecretProviderKind,
        capabilities: Set<HostwrightSecretProviderCapability>
    ) throws {
        guard providerID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw SecretStoreError.invalidReference(
                "Secret provider identifiers must use 1...128 stable ASCII characters."
            )
        }
        guard providerVersion.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw SecretStoreError.backendUnavailable(
                "Secret provider versions must use 1...128 stable ASCII characters."
            )
        }
        guard capabilities.contains(.resolve) else {
            throw SecretStoreError.backendUnavailable(
                "A registered secret provider must advertise resolution support."
            )
        }
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.kind = kind
        self.capabilities = capabilities
    }
}

public struct HostwrightSecretWorkloadScope: Equatable, Hashable, Sendable {
    public let projectID: UUID
    public let resourceID: UUID
    public let generation: Int
    public let serviceName: String

    public init(
        projectID: UUID,
        resourceID: UUID,
        generation: Int,
        serviceName: String
    ) throws {
        guard generation > 0 else {
            throw SecretStoreError.invalidReference(
                "Secret workload generations must be positive."
            )
        }
        guard serviceName.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw SecretStoreError.invalidReference(
                "Secret workload service names must use 1...128 stable ASCII characters."
            )
        }
        self.projectID = projectID
        self.resourceID = resourceID
        self.generation = generation
        self.serviceName = serviceName
    }
}

public struct HostwrightSecretProviderGrant: Equatable, Hashable, Sendable {
    public let providerID: String
    public let reference: HostwrightSecretReference
    public let workload: HostwrightSecretWorkloadScope
    public let environmentKey: String
    public let validFrom: Date?
    public let expiresAt: Date?

    public init(
        providerID: String,
        reference: HostwrightSecretReference,
        workload: HostwrightSecretWorkloadScope,
        environmentKey: String,
        validFrom: Date? = nil,
        expiresAt: Date? = nil
    ) throws {
        guard providerID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw SecretStoreError.invalidReference(
                "Secret provider grants require a stable provider identifier."
            )
        }
        guard environmentKey.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw SecretStoreError.invalidReference(
                "Secret provider grants require a valid environment key."
            )
        }
        if let validFrom, let expiresAt, expiresAt <= validFrom {
            throw SecretStoreError.invalidReference(
                "Secret provider grant expiry must follow its activation time."
            )
        }
        self.providerID = providerID
        self.reference = reference
        self.workload = workload
        self.environmentKey = environmentKey
        self.validFrom = validFrom
        self.expiresAt = expiresAt
    }
}

public struct HostwrightSecretProviderRequest: Sendable {
    public let reference: HostwrightSecretReference
    public let workload: HostwrightSecretWorkloadScope
    public let environmentKey: String
    public let resolutionTime: Date
    private let cancellationCheck: @Sendable () -> Bool

    public init(
        reference: HostwrightSecretReference,
        workload: HostwrightSecretWorkloadScope,
        environmentKey: String,
        resolutionTime: Date,
        cancellationCheck: @escaping @Sendable () -> Bool = {
            var cancelled = false
            withUnsafeCurrentTask { task in
                cancelled = task?.isCancelled ?? false
            }
            return cancelled
        }
    ) {
        self.reference = reference
        self.workload = workload
        self.environmentKey = environmentKey
        self.resolutionTime = resolutionTime
        self.cancellationCheck = cancellationCheck
    }

    public func requireNotCancelled() throws {
        guard !cancellationCheck() else {
            throw SecretStoreError.cancelled(
                "Secret provider resolution was cancelled."
            )
        }
    }
}

public struct HostwrightSecretResolutionMetadata: Equatable, Sendable {
    public let providerID: String
    public let providerKind: HostwrightSecretProviderKind
    public let version: String
    public let observedAt: Date
    public let refreshAfter: Date?
    public let expiresAt: Date?

    public init(
        providerID: String,
        providerKind: HostwrightSecretProviderKind,
        version: String,
        observedAt: Date,
        refreshAfter: Date? = nil,
        expiresAt: Date? = nil
    ) throws {
        guard providerID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned invalid identity metadata."
            )
        }
        guard version.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned invalid version metadata."
            )
        }
        if let refreshAfter, refreshAfter < observedAt {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned invalid refresh metadata."
            )
        }
        if let expiresAt, expiresAt <= observedAt {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned an already expired value."
            )
        }
        if let refreshAfter, let expiresAt, refreshAfter >= expiresAt {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned inconsistent refresh metadata."
            )
        }
        self.providerID = providerID
        self.providerKind = providerKind
        self.version = version
        self.observedAt = observedAt
        self.refreshAfter = refreshAfter
        self.expiresAt = expiresAt
    }
}

public struct HostwrightSecretResolution: Sendable {
    public let metadata: HostwrightSecretResolutionMetadata
    private let value: HostwrightSecretValue

    public init(
        value: HostwrightSecretValue,
        metadata: HostwrightSecretResolutionMetadata
    ) {
        self.value = value
        self.metadata = metadata
    }

    public var byteCount: Int {
        value.byteCount
    }

    public func stringValue() -> String {
        value.dataString()
    }
}

public protocol HostwrightSecretProvider: Sendable {
    var descriptor: HostwrightSecretProviderDescriptor { get }
    func resolve(
        _ request: HostwrightSecretProviderRequest
    ) throws -> HostwrightSecretResolution
}

public protocol HostwrightSecretResolving: Sendable {
    func resolve(
        reference: HostwrightSecretReference,
        for workload: HostwrightSecretWorkloadScope,
        environmentKey: String,
        at resolutionTime: Date
    ) throws -> HostwrightSecretResolution
}

public struct HostwrightSecretProviderRegistry: HostwrightSecretResolving, Sendable {
    private struct GrantKey: Equatable, Hashable, Sendable {
        let providerID: String
        let reference: HostwrightSecretReference
        let workload: HostwrightSecretWorkloadScope
        let environmentKey: String
    }

    private let providers: [String: any HostwrightSecretProvider]
    private let grants: [GrantKey: HostwrightSecretProviderGrant]

    public init(
        providers: [any HostwrightSecretProvider],
        grants: [HostwrightSecretProviderGrant]
    ) throws {
        var indexedProviders: [String: any HostwrightSecretProvider] = [:]
        for provider in providers {
            let descriptor = provider.descriptor
            guard indexedProviders[descriptor.providerID] == nil else {
                throw SecretStoreError.backendUnavailable(
                    "A secret provider identifier was registered more than once."
                )
            }
            guard Self.isValidRegistration(descriptor) else {
                throw SecretStoreError.backendUnavailable(
                    "A secret provider registration does not match its provider kind."
                )
            }
            indexedProviders[descriptor.providerID] = provider
        }

        var indexedGrants: [GrantKey: HostwrightSecretProviderGrant] = [:]
        for grant in grants {
            guard grant.providerID == Self.providerID(
                for: grant.reference
            ) else {
                throw SecretStoreError.invalidReference(
                    "A secret provider grant does not match its typed reference."
                )
            }
            let key = GrantKey(
                providerID: grant.providerID,
                reference: grant.reference,
                workload: grant.workload,
                environmentKey: grant.environmentKey
            )
            guard indexedGrants[key] == nil else {
                throw SecretStoreError.invalidReference(
                    "An exact secret provider grant was declared more than once."
                )
            }
            indexedGrants[key] = grant
        }
        self.providers = indexedProviders
        self.grants = indexedGrants
    }

    public func resolve(
        reference: HostwrightSecretReference,
        for workload: HostwrightSecretWorkloadScope,
        environmentKey: String,
        at resolutionTime: Date = Date()
    ) throws -> HostwrightSecretResolution {
        try Self.requireNotCancelled()
        let providerID = Self.providerID(for: reference)
        let key = GrantKey(
            providerID: providerID,
            reference: reference,
            workload: workload,
            environmentKey: environmentKey
        )
        guard let grant = grants[key] else {
            throw SecretStoreError.permissionDenied(
                "Secret resolution is not authorized for this exact workload boundary."
            )
        }
        if let validFrom = grant.validFrom, resolutionTime < validFrom {
            throw SecretStoreError.permissionDenied(
                "Secret resolution grant is not active for this workload boundary."
            )
        }
        if let expiresAt = grant.expiresAt, resolutionTime >= expiresAt {
            throw SecretStoreError.permissionDenied(
                "Secret resolution grant has expired for this workload boundary."
            )
        }
        guard let provider = providers[providerID],
              provider.descriptor.kind == reference.providerKind else {
            throw SecretStoreError.backendUnavailable(
                "The requested secret provider is not registered."
            )
        }

        let request = HostwrightSecretProviderRequest(
            reference: reference,
            workload: workload,
            environmentKey: environmentKey,
            resolutionTime: resolutionTime
        )
        try request.requireNotCancelled()
        let result: HostwrightSecretResolution
        do {
            result = try provider.resolve(request)
        } catch let error as SecretStoreError {
            throw Self.sanitized(error)
        } catch {
            throw SecretStoreError.backendUnavailable(
                "Secret provider resolution failed."
            )
        }
        try request.requireNotCancelled()
        guard result.byteCount <= HostwrightSecretValue.maximumByteCount else {
            throw SecretStoreError.invalidValue(
                "Secret provider value exceeds the 64 KiB limit."
            )
        }
        guard result.metadata.providerID == providerID,
              result.metadata.providerKind == reference.providerKind else {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned mismatched identity metadata."
            )
        }
        if let expiresAt = result.metadata.expiresAt,
           resolutionTime >= expiresAt {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned an expired value."
            )
        }
        if result.metadata.expiresAt != nil,
           !provider.descriptor.capabilities.contains(.expiring) {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned expiry metadata without advertising that capability."
            )
        }
        if let refreshAfter = result.metadata.refreshAfter,
           resolutionTime >= refreshAfter {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned a value that requires refresh."
            )
        }
        if result.metadata.refreshAfter != nil,
           !provider.descriptor.capabilities.contains(.refresh) {
            throw SecretStoreError.backendUnavailable(
                "Secret provider returned refresh metadata without advertising that capability."
            )
        }
        return result
    }

    private static func requireNotCancelled() throws {
        var cancelled = false
        withUnsafeCurrentTask { task in
            cancelled = task?.isCancelled ?? false
        }
        guard !cancelled else {
            throw SecretStoreError.cancelled(
                "Secret provider resolution was cancelled."
            )
        }
    }

    public static func providerID(
        for reference: HostwrightSecretReference
    ) -> String {
        switch reference.providerKind {
        case .keychain, .environmentFile, .localFile:
            return reference.providerKind.rawValue
        case .external, .plugin:
            return reference.service
        }
    }

    private static func isValidRegistration(
        _ descriptor: HostwrightSecretProviderDescriptor
    ) -> Bool {
        switch descriptor.kind {
        case .keychain, .environmentFile, .localFile:
            return descriptor.providerID == descriptor.kind.rawValue
        case .external, .plugin:
            return true
        }
    }

    private static func sanitized(
        _ error: SecretStoreError
    ) -> SecretStoreError {
        switch error {
        case .invalidReference:
            return .invalidReference("Secret provider rejected the typed reference.")
        case .invalidValue:
            return .invalidValue("Secret provider returned an invalid bounded value.")
        case .backendUnavailable:
            return .backendUnavailable("Secret provider is unavailable.")
        case .notFound:
            return .notFound("Secret provider did not contain the requested value.")
        case .duplicate:
            return .duplicate("Secret provider returned duplicate data.")
        case .unmanaged:
            return .unmanaged("Secret provider rejected unmanaged data.")
        case .permissionDenied:
            return .permissionDenied("Secret provider denied resolution.")
        case .interactionNotAllowed:
            return .interactionNotAllowed("Secret provider requires disallowed interaction.")
        case .cancelled:
            return .cancelled("Secret provider resolution was cancelled.")
        case .concurrentMutation:
            return .concurrentMutation("Secret provider data changed during resolution.")
        case .corruptedMetadata:
            return .corruptedMetadata("Secret provider returned invalid metadata.")
        case .partialEffect:
            return .partialEffect("Secret provider reported an ambiguous effect.")
        }
    }
}

public func hostwrightDefaultSecretResolver(
    store: any SecretStore
) -> any HostwrightSecretResolving {
    HostwrightManifestSecretResolver(
        providers: [
            HostwrightKeychainSecretProvider(store: store),
            HostwrightEnvironmentFileSecretProvider(),
            HostwrightLocalFileSecretProvider()
        ]
    )
}

private struct HostwrightManifestSecretResolver: HostwrightSecretResolving {
    let providers: [any HostwrightSecretProvider]

    func resolve(
        reference: HostwrightSecretReference,
        for workload: HostwrightSecretWorkloadScope,
        environmentKey: String,
        at resolutionTime: Date
    ) throws -> HostwrightSecretResolution {
        let grant = try HostwrightSecretProviderGrant(
            providerID: HostwrightSecretProviderRegistry.providerID(
                for: reference
            ),
            reference: reference,
            workload: workload,
            environmentKey: environmentKey
        )
        return try HostwrightSecretProviderRegistry(
            providers: providers,
            grants: [grant]
        ).resolve(
            reference: reference,
            for: workload,
            environmentKey: environmentKey,
            at: resolutionTime
        )
    }
}

public struct HostwrightKeychainSecretProvider: HostwrightSecretProvider {
    public let descriptor: HostwrightSecretProviderDescriptor
    private let store: any SecretStore

    public init(manager: any SecretManager = MacOSKeychainSecretStore()) {
        self.init(store: manager)
    }

    public init(store: any SecretStore) {
        self.store = store
        self.descriptor = try! HostwrightSecretProviderDescriptor(
            providerID: HostwrightSecretProviderKind.keychain.rawValue,
            kind: .keychain,
            capabilities: [.resolve, .versioned]
        )
    }

    public func resolve(
        _ request: HostwrightSecretProviderRequest
    ) throws -> HostwrightSecretResolution {
        try request.requireNotCancelled()
        guard request.reference.providerKind == .keychain else {
            throw SecretStoreError.invalidReference(
                "Keychain provider received an incompatible secret reference."
            )
        }
        let version: String
        let rawValue: String
        if let manager = store as? any SecretManager {
            let before = try manager.check(reference: request.reference)
            rawValue = try manager.readString(reference: request.reference)
            let after = try manager.check(reference: request.reference)
            guard before.itemID == after.itemID,
                  before.version == after.version else {
                throw SecretStoreError.concurrentMutation(
                    "Keychain secret changed while it was being resolved."
                )
            }
            version = "\(after.itemID.uuidString.lowercased()):\(after.version)"
        } else {
            rawValue = try store.readString(reference: request.reference)
            version = "store-v1"
        }
        try request.requireNotCancelled()
        return HostwrightSecretResolution(
            value: try HostwrightSecretValue(rawValue),
            metadata: try HostwrightSecretResolutionMetadata(
                providerID: descriptor.providerID,
                providerKind: descriptor.kind,
                version: version,
                observedAt: request.resolutionTime
            )
        )
    }
}

public struct HostwrightEnvironmentFileSecretProvider: HostwrightSecretProvider {
    public let descriptor: HostwrightSecretProviderDescriptor

    public init() {
        self.descriptor = try! HostwrightSecretProviderDescriptor(
            providerID: HostwrightSecretProviderKind.environmentFile.rawValue,
            kind: .environmentFile,
            capabilities: [.resolve, .versioned]
        )
    }

    public func resolve(
        _ request: HostwrightSecretProviderRequest
    ) throws -> HostwrightSecretResolution {
        try request.requireNotCancelled()
        guard request.reference.providerKind == .environmentFile else {
            throw SecretStoreError.invalidReference(
                "Environment-file provider received an incompatible secret reference."
            )
        }
        let file = try GuardedSecretFileReader.read(
            path: request.reference.service
        )
        guard let document = String(data: file.data, encoding: .utf8) else {
            throw SecretStoreError.invalidValue(
                "Environment-file secret data must contain valid UTF-8."
            )
        }
        var values: [String: String] = [:]
        for rawLine in document.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            var line = String(rawLine)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw SecretStoreError.backendUnavailable(
                    "Environment-file provider returned invalid or ambiguous data."
                )
            }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard key.range(
                of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#,
                options: .regularExpression
            ) != nil,
                  values[key] == nil else {
                throw SecretStoreError.backendUnavailable(
                    "Environment-file provider returned invalid or ambiguous data."
                )
            }
            values[key] = value
        }
        guard let rawValue = values[request.reference.account] else {
            throw SecretStoreError.notFound(
                "Environment-file provider did not contain the requested value."
            )
        }
        try request.requireNotCancelled()
        return HostwrightSecretResolution(
            value: try HostwrightSecretValue(rawValue),
            metadata: try HostwrightSecretResolutionMetadata(
                providerID: descriptor.providerID,
                providerKind: descriptor.kind,
                version: file.version,
                observedAt: request.resolutionTime
            )
        )
    }
}

public struct HostwrightLocalFileSecretProvider: HostwrightSecretProvider {
    public let descriptor: HostwrightSecretProviderDescriptor

    public init() {
        self.descriptor = try! HostwrightSecretProviderDescriptor(
            providerID: HostwrightSecretProviderKind.localFile.rawValue,
            kind: .localFile,
            capabilities: [.resolve, .versioned]
        )
    }

    public func resolve(
        _ request: HostwrightSecretProviderRequest
    ) throws -> HostwrightSecretResolution {
        try request.requireNotCancelled()
        guard request.reference.providerKind == .localFile else {
            throw SecretStoreError.invalidReference(
                "Local-file provider received an incompatible secret reference."
            )
        }
        let file = try GuardedSecretFileReader.read(
            path: request.reference.service
        )
        try request.requireNotCancelled()
        return HostwrightSecretResolution(
            value: try HostwrightSecretValue(utf8Data: file.data),
            metadata: try HostwrightSecretResolutionMetadata(
                providerID: descriptor.providerID,
                providerKind: descriptor.kind,
                version: file.version,
                observedAt: request.resolutionTime
            )
        )
    }
}

private enum GuardedSecretFileReader {
    struct Result {
        let data: Data
        let version: String
    }

    static func read(path: String) throws -> Result {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard !components.isEmpty else {
            throw unsafePath()
        }

        var directory = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw unsafePath()
        }
        defer { Darwin.close(directory) }
        try validateDirectory(directory)

        for component in components.dropLast() {
            let child = component.withCString {
                Darwin.openat(
                    directory,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard child >= 0 else {
                throw unsafePath()
            }
            do {
                try validateDirectory(child)
            } catch {
                Darwin.close(child)
                throw error
            }
            Darwin.close(directory)
            directory = child
        }

        let finalName = components[components.count - 1]
        let descriptor = finalName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw unsafePath()
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == Darwin.geteuid(),
              before.st_nlink == 1,
              before.st_mode & 0o077 == 0,
              before.st_size >= 0 else {
            throw unsafePath()
        }
        guard before.st_size <= HostwrightSecretValue.maximumByteCount else {
            throw SecretStoreError.invalidValue(
                "File-backed secret value exceeds the 64 KiB limit."
            )
        }
        try validateNoAccessGrantingACL(descriptor)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw unsafePath()
            }
            guard data.count + count <= HostwrightSecretValue.maximumByteCount else {
                throw SecretStoreError.invalidValue(
                    "File-backed secret value exceeds the 64 KiB limit."
                )
            }
            data.append(buffer, count: count)
        }

        var after = stat()
        var named = stat()
        let namedStatus = finalName.withCString {
            Darwin.fstatat(
                directory,
                $0,
                &named,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard Darwin.fstat(descriptor, &after) == 0,
              namedStatus == 0,
              identity(before) == identity(after),
              identity(before) == identity(named),
              Int64(data.count) == after.st_size else {
            throw SecretStoreError.concurrentMutation(
                "File-backed secret changed while it was being resolved."
            )
        }
        return Result(data: data, version: version(after))
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == 0 || metadata.st_uid == Darwin.geteuid() else {
            throw unsafePath()
        }
        let writableByOthers = metadata.st_mode & 0o022 != 0
        let protectedSharedDirectory =
            metadata.st_uid == 0 && metadata.st_mode & mode_t(S_ISVTX) != 0
        guard !writableByOthers || protectedSharedDirectory else {
            throw unsafePath()
        }
        try validateNoAccessGrantingACL(descriptor)
    }

    private static func validateNoAccessGrantingACL(
        _ descriptor: Int32
    ) throws {
        errno = 0
        guard let accessControlList = acl_get_fd_np(
            descriptor,
            ACL_TYPE_EXTENDED
        ) else {
            if errno == ENOENT || errno == ENOTSUP {
                return
            }
            throw unsafePath()
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }

        var entry: acl_entry_t?
        var entryID = ACL_FIRST_ENTRY.rawValue
        while true {
            errno = 0
            let result = acl_get_entry(
                accessControlList,
                entryID,
                &entry
            )
            if result != 0 {
                if errno == EINVAL {
                    return
                }
                throw unsafePath()
            }
            guard let entry else {
                throw unsafePath()
            }
            var tag = acl_tag_t(0)
            guard acl_get_tag_type(entry, &tag) == 0,
                  tag == ACL_EXTENDED_DENY else {
                throw unsafePath()
            }
            entryID = ACL_NEXT_ENTRY.rawValue
        }
    }

    private static func identity(
        _ metadata: stat
    ) -> FileIdentity {
        FileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            mode: UInt16(metadata.st_mode),
            owner: UInt32(metadata.st_uid),
            links: UInt16(metadata.st_nlink),
            size: Int64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }

    private static func version(_ metadata: stat) -> String {
        [
            String(UInt64(metadata.st_dev), radix: 16),
            String(UInt64(metadata.st_ino), radix: 16),
            String(Int64(metadata.st_size), radix: 16),
            String(
                UInt64(bitPattern: Int64(metadata.st_mtimespec.tv_sec)),
                radix: 16
            ),
            String(
                UInt64(bitPattern: Int64(metadata.st_mtimespec.tv_nsec)),
                radix: 16
            )
        ].joined(separator: ":")
    }

    private static func unsafePath() -> SecretStoreError {
        .permissionDenied(
            "File-backed secret could not be read through the guarded local-file boundary."
        )
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt16
        let owner: UInt32
        let links: UInt16
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }
}

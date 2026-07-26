import Darwin
import Foundation
import HostwrightCore
import Security

let storageCodeSigningRevocationFlag: UInt32 = UInt32(1) << 30

public enum StorageProviderHelperBootstrapError:
    Error,
    Equatable,
    Sendable
{
    case invalidConfiguration
    case executableUnavailable
    case unsafeExecutable
    case signerMismatch
    case signerRevoked
    case executableChanged
    case unsafeRuntimeDirectory
    case socketUnavailable
    case socketUnsafe
    case launchFailed
    case helperExited
    case timedOut
    case cancelled
    case frameTooLarge
    case peerAuthenticationFailed
    case cleanupFailed
}

public struct StorageProviderHelperBootstrapConfiguration:
    Equatable,
    Sendable
{
    public let executableURL: URL
    public let runtimeDirectoryURL: URL
    public let socketURL: URL
    public let providerRootURL: URL
    public let capacityBytes: Int64
    public let launchTimeoutMilliseconds: Int64
    public let requestTimeoutMilliseconds: Int64

    public init(
        executableURL: URL,
        runtimeDirectoryURL: URL,
        providerRootURL: URL,
        capacityBytes: Int64,
        launchTimeoutMilliseconds: Int64 = 5_000,
        requestTimeoutMilliseconds: Int64 = 30_000
    ) throws {
        guard Self.validAbsoluteNormalizedPath(executableURL.path),
              executableURL.lastPathComponent ==
                StorageProviderPeerIdentityPolicy.helperCodeIdentifier,
              (1...60_000).contains(launchTimeoutMilliseconds),
              (1...StorageProviderContract
                  .maximumDeadlineWindowMilliseconds)
                .contains(requestTimeoutMilliseconds) else {
            throw StorageProviderHelperBootstrapError.invalidConfiguration
        }
        let runConfiguration: StorageProviderHelperRunConfiguration
        do {
            runConfiguration = try StorageProviderHelperRunConfiguration(
                runtimeDirectoryURL: runtimeDirectoryURL,
                providerRootURL: providerRootURL,
                capacityBytes: capacityBytes
            )
        } catch {
            throw StorageProviderHelperBootstrapError.invalidConfiguration
        }
        let normalizedExecutableURL = URL(
            fileURLWithPath: executableURL.path,
            isDirectory: false
        )
        self.executableURL = normalizedExecutableURL
        self.runtimeDirectoryURL =
            runConfiguration.runtimeDirectoryURL
        socketURL = runConfiguration.runtimeDirectoryURL
            .appendingPathComponent(
                StorageProviderRuntimeDirectory.socketName,
                isDirectory: false
            )
        self.providerRootURL = runConfiguration.providerRootURL
        self.capacityBytes = runConfiguration.capacityBytes
        self.launchTimeoutMilliseconds = launchTimeoutMilliseconds
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
    }

    public static func installed(
        hostExecutableURL: URL? = Bundle.main.executableURL,
        homeDirectoryURL: URL =
            FileManager.default.homeDirectoryForCurrentUser,
        capacityBytes: Int64 = 1_099_511_627_776
    ) throws -> StorageProviderHelperBootstrapConfiguration {
        guard let hostExecutableURL else {
            throw StorageProviderHelperBootstrapError.invalidConfiguration
        }
        let helperURL = hostExecutableURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                StorageProviderPeerIdentityPolicy.helperCodeIdentifier,
                isDirectory: false
            )
        let supportURL = homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
            .appendingPathComponent("Hostwright", isDirectory: true)
        return try StorageProviderHelperBootstrapConfiguration(
            executableURL: helperURL,
            runtimeDirectoryURL: supportURL
                .appendingPathComponent("run", isDirectory: true)
                .appendingPathComponent(
                    "storage-provider",
                    isDirectory: true
                ),
            providerRootURL: LocalStorageProvider.defaultRootURL(
                homeDirectory: homeDirectoryURL
            ),
            capacityBytes: capacityBytes
        )
    }

    private static func validAbsoluteNormalizedPath(
        _ path: String
    ) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              path.utf8.count <= Int(PATH_MAX),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.first?.isEmpty == true &&
            components.dropFirst().allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

public struct StorageProviderHelperExecutableValidator: Sendable {
    private let validation: @Sendable (
        URL
    ) throws -> SecureExecutableIdentity
    private let unchangedValidation: @Sendable (
        SecureExecutableIdentity
    ) throws -> Void

    public init(
        validate: @escaping @Sendable (
            URL
        ) throws -> SecureExecutableIdentity,
        verifyUnchanged: @escaping @Sendable (
            SecureExecutableIdentity
        ) throws -> Void
    ) {
        validation = validate
        unchangedValidation = verifyUnchanged
    }

    public func validate(
        _ executableURL: URL
    ) throws -> SecureExecutableIdentity {
        try validation(executableURL)
    }

    public func verifyUnchanged(
        _ identity: SecureExecutableIdentity
    ) throws {
        try unchangedValidation(identity)
    }

    public static let signed = StorageProviderHelperExecutableValidator(
        validate: { executableURL in
            try StorageProviderHelperSignedExecutable.validate(
                executableURL
            )
        },
        verifyUnchanged: { identity in
            do {
                try SecureExecutableResolver.verifyUnchanged(identity)
                try StorageProviderHelperSignedExecutable.validateSignature(
                    URL(
                        fileURLWithPath: identity.path,
                        isDirectory: false
                    )
                )
            } catch let error as StorageProviderHelperBootstrapError {
                throw error
            } catch SecureExecutableValidationError.metadataChanged {
                throw StorageProviderHelperBootstrapError.executableChanged
            } catch {
                throw StorageProviderHelperBootstrapError.unsafeExecutable
            }
        }
    )
}

private enum StorageProviderHelperSignedExecutable {
    static func validate(
        _ executableURL: URL
    ) throws -> SecureExecutableIdentity {
        var metadata = stat()
        guard lstat(executableURL.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                throw StorageProviderHelperBootstrapError
                    .executableUnavailable
            }
            throw StorageProviderHelperBootstrapError.unsafeExecutable
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw StorageProviderHelperBootstrapError.unsafeExecutable
        }

        let identity: SecureExecutableIdentity
        do {
            identity = try SecureExecutableResolver.verify(
                path: executableURL.path,
                ownershipPolicy: .rootOrCurrentUser
            )
        } catch SecureExecutableValidationError.pathDoesNotExist {
            throw StorageProviderHelperBootstrapError.executableUnavailable
        } catch {
            throw StorageProviderHelperBootstrapError.unsafeExecutable
        }
        guard identity.path == executableURL.path,
              URL(fileURLWithPath: identity.path).lastPathComponent ==
                StorageProviderPeerIdentityPolicy.helperCodeIdentifier else {
            throw StorageProviderHelperBootstrapError.unsafeExecutable
        }
        try validateSignature(executableURL)
        do {
            try SecureExecutableResolver.verifyUnchanged(identity)
        } catch {
            throw StorageProviderHelperBootstrapError.executableChanged
        }
        return identity
    }

    static func validateSignature(_ executableURL: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            throw StorageProviderHelperBootstrapError.signerMismatch
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let values = signingInformation as? [String: Any],
        values[kSecCodeInfoIdentifier as String] as? String ==
            StorageProviderPeerIdentityPolicy.helperCodeIdentifier,
        values[kSecCodeInfoTeamIdentifier as String] as? String ==
            StorageProviderPeerIdentityPolicy.expectedTeamIdentifier else {
            throw StorageProviderHelperBootstrapError.signerMismatch
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            StorageProviderPeerIdentityPolicy
                .helperDesignatedRequirement as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else {
            throw StorageProviderHelperBootstrapError.signerMismatch
        }
        let status = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(
                rawValue:
                    kSecCSStrictValidate |
                    kSecCSCheckAllArchitectures |
                    storageCodeSigningRevocationFlag
            ),
            requirement
        )
        guard status == errSecSuccess else {
            if status == errSecCertificateRevoked {
                throw StorageProviderHelperBootstrapError
                    .signerRevoked
            }
            throw StorageProviderHelperBootstrapError.signerMismatch
        }
    }
}

public struct StorageProviderHelperBootstrap: Sendable {
    public let configuration: StorageProviderHelperBootstrapConfiguration

    private let executableValidator:
        StorageProviderHelperExecutableValidator
    private let launcher: StorageProviderHelperProcessLauncher
    private let transport: StorageProviderClientTransport

    public init(
        configuration: StorageProviderHelperBootstrapConfiguration,
        executableValidator:
            StorageProviderHelperExecutableValidator = .signed,
        launcher: StorageProviderHelperProcessLauncher = .system,
        transport: StorageProviderClientTransport = .unix()
    ) {
        self.configuration = configuration
        self.executableValidator = executableValidator
        self.launcher = launcher
        self.transport = transport
    }

    public func launch() async throws -> StorageProviderHelperSession {
        let identity: SecureExecutableIdentity
        do {
            identity = try executableValidator.validate(
                configuration.executableURL
            )
        } catch let error as StorageProviderHelperBootstrapError {
            throw error
        } catch {
            throw StorageProviderHelperBootstrapError.unsafeExecutable
        }

        let runtimeDirectory: StorageProviderRuntimeDirectory
        do {
            runtimeDirectory = try prepareRuntimeDirectory()
        } catch let error as StorageProviderHelperBootstrapError {
            throw error
        } catch {
            throw StorageProviderHelperBootstrapError
                .unsafeRuntimeDirectory
        }

        let process: StorageProviderHelperProcessLease
        do {
            process = try launcher.launch(
                configuration: configuration,
                executableIdentity: identity
            )
        } catch {
            try? cleanup(runtimeDirectory)
            throw (error as? StorageProviderHelperBootstrapError)
                ?? .launchFailed
        }

        do {
            try executableValidator.verifyUnchanged(identity)
            try process.resume()
            try await waitForSocket(
                process: process,
                runtimeDirectory: runtimeDirectory
            )
            return StorageProviderHelperSession(
                configuration: configuration,
                process: process,
                runtimeDirectory: runtimeDirectory,
                transport: transport
            )
        } catch {
            process.terminate()
            try? cleanup(runtimeDirectory)
            if Task.isCancelled || error is CancellationError {
                throw StorageProviderHelperBootstrapError.cancelled
            }
            if let error =
                error as? StorageProviderHelperBootstrapError {
                throw error
            }
            if error is StorageProviderTransportError {
                throw StorageProviderHelperBootstrapError.socketUnsafe
            }
            throw StorageProviderHelperBootstrapError.launchFailed
        }
    }

    private func prepareRuntimeDirectory() throws
        -> StorageProviderRuntimeDirectory
    {
        let runtime = try StorageProviderRuntimeDirectory.prepare(
            at: configuration.runtimeDirectoryURL
        )
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: configuration.runtimeDirectoryURL.path
        )
        guard entries.allSatisfy({
            $0 == StorageProviderRuntimeDirectory.socketName
        }) else {
            throw StorageProviderHelperBootstrapError
                .unsafeRuntimeDirectory
        }
        if entries.contains(StorageProviderRuntimeDirectory.socketName) {
            try removeOwnedSocket()
        }
        return runtime
    }

    private func waitForSocket(
        process: StorageProviderHelperProcessLease,
        runtimeDirectory: StorageProviderRuntimeDirectory
    ) async throws {
        let deadline = monotonicMilliseconds() +
            configuration.launchTimeoutMilliseconds
        while monotonicMilliseconds() < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw StorageProviderHelperBootstrapError.helperExited
            }
            do {
                try runtimeDirectory.validateCurrentDirectory()
                if try validateSocketIfPresent() {
                    return
                }
            } catch let error as StorageProviderHelperBootstrapError {
                throw error
            } catch {
                throw StorageProviderHelperBootstrapError.socketUnsafe
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw StorageProviderHelperBootstrapError.timedOut
    }

    private func validateSocketIfPresent() throws -> Bool {
        var metadata = stat()
        guard lstat(configuration.socketURL.path, &metadata) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw StorageProviderHelperBootstrapError.socketUnsafe
        }
        guard (metadata.st_mode & S_IFMT) == S_IFSOCK,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o7777 == 0o600 else {
            throw StorageProviderHelperBootstrapError.socketUnsafe
        }
        return true
    }

    private func removeOwnedSocket() throws {
        guard try validateSocketIfPresent(),
              unlink(configuration.socketURL.path) == 0 else {
            throw StorageProviderHelperBootstrapError.socketUnsafe
        }
    }

    fileprivate func cleanup(
        _ runtimeDirectory: StorageProviderRuntimeDirectory
    ) throws {
        try StorageProviderHelperCleanup.perform(
            runtimeDirectory: runtimeDirectory
        )
    }
}

public actor StorageProviderHelperSession {
    public nonisolated let processID: pid_t

    private let configuration:
        StorageProviderHelperBootstrapConfiguration
    private let process: StorageProviderHelperProcessLease
    private let runtimeDirectory: StorageProviderRuntimeDirectory
    private let transport: StorageProviderClientTransport
    private var closed = false

    fileprivate init(
        configuration: StorageProviderHelperBootstrapConfiguration,
        process: StorageProviderHelperProcessLease,
        runtimeDirectory: StorageProviderRuntimeDirectory,
        transport: StorageProviderClientTransport
    ) {
        self.configuration = configuration
        self.process = process
        self.runtimeDirectory = runtimeDirectory
        self.transport = transport
        processID = process.processID
    }

    public func exchange(
        frame: Data,
        deadlineUnixMilliseconds: Int64? = nil
    ) async throws -> StorageProviderTransportResponse {
        guard !closed, process.isRunning else {
            throw StorageProviderHelperBootstrapError.helperExited
        }
        guard frame.count <= StorageProviderContract.maximumRequestBytes +
                StorageProviderFraming.headerBytes else {
            try closeAfterFailure()
            throw StorageProviderHelperBootstrapError.frameTooLarge
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let defaultDeadline = now +
            configuration.requestTimeoutMilliseconds
        let deadline = deadlineUnixMilliseconds ?? defaultDeadline
        let maximumDeadline = now +
            StorageProviderContract.maximumDeadlineWindowMilliseconds
        guard deadline > now,
              deadline <= maximumDeadline else {
            try closeAfterFailure()
            throw StorageProviderHelperBootstrapError.timedOut
        }

        do {
            let response = try await transport.exchange(
                frame: frame,
                socketURL: configuration.socketURL,
                deadlineUnixMilliseconds: deadline,
                expectedProcessID: processID
            )
            guard response.frame.count <=
                    StorageProviderContract.maximumResultBytes +
                    StorageProviderFraming.headerBytes else {
                throw StorageProviderHelperBootstrapError.frameTooLarge
            }
            guard response.peerProcessID == processID else {
                throw StorageProviderHelperBootstrapError
                    .peerAuthenticationFailed
            }
            return response
        } catch {
            try closeAfterFailure()
            if Task.isCancelled || error is CancellationError {
                throw StorageProviderHelperBootstrapError.cancelled
            }
            if let error =
                error as? StorageProviderHelperBootstrapError {
                throw error
            }
            if let error = error as? StorageProviderTransportError {
                throw Self.mapTransportError(error)
            }
            throw StorageProviderHelperBootstrapError.launchFailed
        }
    }

    public func close() throws {
        guard !closed else {
            return
        }
        closed = true
        process.terminate()
        do {
            try StorageProviderHelperCleanup.perform(
                runtimeDirectory: runtimeDirectory
            )
        } catch {
            throw StorageProviderHelperBootstrapError.cleanupFailed
        }
    }

    private func closeAfterFailure() throws {
        do {
            try close()
        } catch {
            throw StorageProviderHelperBootstrapError.cleanupFailed
        }
    }

    private static func mapTransportError(
        _ error: StorageProviderTransportError
    ) -> StorageProviderHelperBootstrapError {
        switch error {
        case .frameTooLarge:
            return .frameTooLarge
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .peerAuthenticationFailed:
            return .peerAuthenticationFailed
        case .socketUnavailable:
            return .socketUnavailable
        case .socketUnsafe, .socketPathReplaced:
            return .socketUnsafe
        case .providerCrashed:
            return .helperExited
        default:
            return .launchFailed
        }
    }

    deinit {
        process.terminate()
        try? StorageProviderHelperCleanup.perform(
            runtimeDirectory: runtimeDirectory
        )
    }
}

private enum StorageProviderHelperCleanup {
    static func perform(
        runtimeDirectory: StorageProviderRuntimeDirectory
    ) throws {
        do {
            try runtimeDirectory.validateCurrentDirectory()
        } catch {
            var metadata = stat()
            if lstat(runtimeDirectory.directoryURL.path, &metadata) != 0,
               errno == ENOENT,
               runtimeDirectory.createdDirectory {
                return
            }
            throw StorageProviderHelperBootstrapError.cleanupFailed
        }
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: runtimeDirectory.directoryURL.path
        )
        guard entries.allSatisfy({
            $0 == StorageProviderRuntimeDirectory.socketName
        }) else {
            throw StorageProviderHelperBootstrapError.cleanupFailed
        }
        if entries.contains(StorageProviderRuntimeDirectory.socketName) {
            var metadata = stat()
            guard lstat(runtimeDirectory.socketURL.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFSOCK,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o7777 == 0o600,
                  unlink(runtimeDirectory.socketURL.path) == 0 else {
                throw StorageProviderHelperBootstrapError.cleanupFailed
            }
        }
        do {
            try runtimeDirectory.cleanupDirectoryIfCreated()
        } catch {
            throw StorageProviderHelperBootstrapError.cleanupFailed
        }
    }
}

private func monotonicMilliseconds() -> Int64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Int64(time.tv_sec) * 1_000 +
        Int64(time.tv_nsec) / 1_000_000
}

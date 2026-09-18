import Darwin
import Foundation
import HostwrightCore
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightState

public struct DistributionOwnerStateProbeRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operationID: String
    public let receipt: DistributionOwnerStateReceipt
    public let executablePath: String
    public let executableSHA256: String
    public let executableCodeIdentity: CodeIdentity

    func validate() throws {
        try receipt.challenge.validate()
        guard schemaVersion == 1, let identifier = UUID(uuidString: operationID),
              identifier.uuidString.lowercased() == operationID,
              receipt.binding.ownerUID != 0,
              executablePath == URL(fileURLWithPath: receipt.challenge.prefix).appendingPathComponent("bin/hostwright-dist").path,
              executableSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              executableCodeIdentity.validationMode == .installedRequirement,
              executableCodeIdentity.signingIdentifier == "hostwright-dist" else {
            throw DistributionError.lifecycleFailed("owner probe descriptor is not exact and signed")
        }
    }
}

public struct DistributionOwnerStateProbeResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operationID: String
    public let requestSHA256: String
    public let ownerUID: UInt32
    public let ownerGID: UInt32
    public let stateRevision: StateUpgradeRevision
    public let auditHead: AuditChainHeadAnchor?
}

public enum DistributionOwnerStateProbe {
    public static func executeRootChild(_ request: DistributionOwnerStateProbeRequest) throws -> DistributionOwnerStateProbeResult {
        guard getuid() == 0, geteuid() == 0 else {
            throw DistributionError.lifecycleFailed("owner probe child must enter from the root launcher")
        }
        try request.validate()
        let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        guard ownPath == request.executablePath,
              try DistributionHash.sha256(fileURL: URL(fileURLWithPath: ownPath)) == request.executableSHA256,
              try DarwinCurrentControlCodeIdentity.inspect(executablePath: ownPath) == request.executableCodeIdentity,
              let account = getpwuid(request.receipt.binding.ownerUID) else {
            throw DistributionError.lifecycleFailed("owner probe executable or account differs from pinned descriptor")
        }
        let userID = account.pointee.pw_uid
        let groupID = account.pointee.pw_gid
        let ownerHome = String(cString: account.pointee.pw_dir)
        guard userID != 0, groupID != 0,
              setgroups(0, nil) == 0, setgid(groupID) == 0, setuid(userID) == 0,
              getuid() == userID, geteuid() == userID, getgid() == groupID, getegid() == groupID else {
            throw DistributionError.lifecycleFailed("owner probe could not irreversibly drop root UID/GID/groups")
        }
        let groupCount = getgroups(0, nil)
        guard groupCount >= 0, groupCount <= 64 else {
            throw DistributionError.lifecycleFailed("owner probe cannot verify dropped supplementary groups")
        }
        var groups = [gid_t](repeating: 0, count: Int(groupCount))
        let checkedGroups = groups.withUnsafeMutableBufferPointer { getgroups(groupCount, $0.baseAddress) }
        guard checkedGroups == groupCount, groups.allSatisfy({ $0 == groupID }) else {
            throw DistributionError.lifecycleFailed("owner probe retained unexpected supplementary groups")
        }
        let configuration = try validatedOwnerConfiguration(request.receipt.binding, homeDirectory: ownerHome)
        let lifecycle = DistributionInstalledLifecycle()
        guard try lifecycle.preparedOwnerStateReceipt(prefix: URL(fileURLWithPath: request.receipt.challenge.prefix),
            configuration: configuration) == request.receipt else {
            throw DistributionError.lifecycleFailed("owner probe receipt changed after root adoption")
        }
        let store = SQLiteStateStore(configuration: configuration)
        let service = StateUpgradeService(store: store)
        return try service.withExclusiveLifecycleFence {
            let keys = try MacOSAuditSigningKeyStore(service: MacOSAuditSigningKeyStore.serviceName(stateDatabasePath: store.path))
            let head = try keys.loadHead()
            let report = TamperEvidentAuditTrail(store: store, keyStore: keys).verify()
            guard report.health == .healthy, let revision = try service.verifiedRevision(),
                  try keys.loadHead() == head else {
                throw DistributionError.lifecycleFailed("owner audit session cannot verify current Keychain head and state")
            }
            return DistributionOwnerStateProbeResult(schemaVersion: 1, operationID: request.operationID,
                requestSHA256: DistributionHash.sha256(data: try DistributionJSON.encode(request)),
                ownerUID: userID, ownerGID: groupID, stateRevision: revision, auditHead: head)
        }
    }

    static func validatedOwnerConfiguration(_ binding: DistributionPreparedStateBinding, homeDirectory: String) throws -> StateStoreConfiguration {
        guard let recorded = binding.localPathResolution else {
            throw DistributionError.lifecycleFailed("owner probe requires actual selected local path resolution")
        }
        var overrides = [HostwrightLocalPathResolver.applicationSupportOverride: recorded.layout.applicationSupportDirectory,
            HostwrightLocalPathResolver.cacheOverride: recorded.layout.cacheDirectory,
            HostwrightLocalPathResolver.logOverride: recorded.layout.logDirectory]
        if recorded.statePathOrigin == .environment { overrides[HostwrightLocalPathResolver.stateDatabaseOverride] = binding.databasePath }
        let actual = try HostwrightLocalPathResolver.resolve(
            explicitStateDatabasePath: recorded.statePathOrigin == .explicit ? binding.databasePath : nil,
            homeDirectory: homeDirectory, environment: overrides)
        let configuration = StateStoreConfiguration(localPathResolution: actual)
        guard actual == recorded, configuration == binding.configuration,
              try configuration.maintenancePaths() == binding.maintenancePaths else {
            throw DistributionError.lifecycleFailed("owner probe configuration does not resolve for the recorded OS owner")
        }
        return configuration
    }
}

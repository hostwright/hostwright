public enum HostwrightContractVersions {
    public static let manifest = 2
    public static let controlAPI = 2
    public static let runtimeProviderAPI = 2
    public static let storageProviderAPI = 1
    public static let pluginABI = 1
    public static let stateSchema = 15
}

public struct HostwrightContractSnapshot: Codable, Equatable, Sendable {
    public let manifest: Int
    public let controlAPI: Int
    public let runtimeProviderAPI: Int
    public let storageProviderAPI: Int
    public let pluginABI: Int
    public let stateSchema: Int

    public init(
        manifest: Int = HostwrightContractVersions.manifest,
        controlAPI: Int = HostwrightContractVersions.controlAPI,
        runtimeProviderAPI: Int = HostwrightContractVersions.runtimeProviderAPI,
        storageProviderAPI: Int =
            HostwrightContractVersions.storageProviderAPI,
        pluginABI: Int = HostwrightContractVersions.pluginABI,
        stateSchema: Int = HostwrightContractVersions.stateSchema
    ) {
        self.manifest = manifest
        self.controlAPI = controlAPI
        self.runtimeProviderAPI = runtimeProviderAPI
        self.storageProviderAPI = storageProviderAPI
        self.pluginABI = pluginABI
        self.stateSchema = stateSchema
    }
}

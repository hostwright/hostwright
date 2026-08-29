public enum HostwrightContractVersions {
    public static let manifest = 3
    public static let controlAPI = 2
    public static let runtimeProviderAPI = 2
    public static let storageProviderAPI = 1
    public static let networkProviderSPI = 1
    public static let pluginABI = 1
    // P09 owns schema 22; P10 appends scheduler and accelerator migrations as 23/24.
    public static let stateSchema = 24
}

public struct HostwrightContractSnapshot: Codable, Equatable, Sendable {
    public let manifest: Int
    public let controlAPI: Int
    public let runtimeProviderAPI: Int
    public let storageProviderAPI: Int
    public let networkProviderSPI: Int
    public let pluginABI: Int
    public let stateSchema: Int

    public init(
        manifest: Int = HostwrightContractVersions.manifest,
        controlAPI: Int = HostwrightContractVersions.controlAPI,
        runtimeProviderAPI: Int = HostwrightContractVersions.runtimeProviderAPI,
        storageProviderAPI: Int =
            HostwrightContractVersions.storageProviderAPI,
        networkProviderSPI: Int =
            HostwrightContractVersions.networkProviderSPI,
        pluginABI: Int = HostwrightContractVersions.pluginABI,
        stateSchema: Int = HostwrightContractVersions.stateSchema
    ) {
        self.manifest = manifest
        self.controlAPI = controlAPI
        self.runtimeProviderAPI = runtimeProviderAPI
        self.storageProviderAPI = storageProviderAPI
        self.networkProviderSPI = networkProviderSPI
        self.pluginABI = pluginABI
        self.stateSchema = stateSchema
    }
}

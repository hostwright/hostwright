import Foundation

public enum ContainerizationRuntimeAssetContract {
    public static let frameworkVersion = "0.35.0"
    public static let frameworkRevision = "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b"

    public static let initImageManifestDigest =
        "e61c8654a20b4b9ec90ae2673764a96aac9bd3054c9d2c9b5c1393f0adbf67f0"
    public static let initImageManifestSize: Int64 = 406
    public static let initImageConfigurationDigest =
        "76509f206856f255171e27a20feaf5fa314d6b9d8cb6959efd6410948a1c70fb"
    public static let initImageConfigurationSize: Int64 = 151
    public static let initImageLayerDigest =
        "33370a8dbc5994627e107cbe34cc44761fd97c6d2cce0b0fae465f56eca808e1"
    public static let initImageLayerSize: Int64 = 67_223_030
    public static let initImageIndexJSONSHA256 =
        "00a14b7036af9ed9f5d29775059870ebaf41fbe5b7953a90441c21cbbbf98285"
    public static let initImageIndexJSONSize: Int64 = 240
    public static let initImageLayoutSHA256 =
        "18f0797eab35a4597c1e9624aa4f15fd91f6254e5538c1e0d193b2a95dd4acc6"
    public static let initImageLayoutSize: Int64 = 30
    public static var initImageReference: String {
        "untagged@sha256:\(initImageManifestDigest)"
    }

    public static let kernelFileName = "vmlinux-6.18.15-186"
    public static let kernelSHA256 =
        "55f86b8394c1d46551836f5c1d3525cdc8d505aeb9bb630c608edb564674239d"
    public static let kernelSize: Int64 = 16_148_992

    public static let guestNetworkPolicyLoaderSHA256 =
        "a411dbcf1efaaf0ea0da17d76e3376a92b99037a8cb00af6588e8ecc6f3f7e99"
    public static let guestNetworkPolicyLoaderSize: Int64 = 2_949_246

    public static let installationRelativeRoot = "share/hostwright/containerization"
    public static let kernelInstallationRelativePath =
        "\(installationRelativeRoot)/kernel/\(kernelFileName)"
    public static let initImageLayoutInstallationRelativePath =
        "\(installationRelativeRoot)/vminit"
    public static let guestNetworkPolicyLoaderFileName =
        "hostwright-netfilter"
    public static let guestNetworkPolicyLoaderInstallationRelativePath =
        "\(installationRelativeRoot)/guest/\(guestNetworkPolicyLoaderFileName)"

    public static var initImageDescriptorDigest: String {
        "sha256:\(initImageManifestDigest)"
    }
}

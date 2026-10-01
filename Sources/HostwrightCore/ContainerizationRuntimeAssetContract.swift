import Foundation

public enum ContainerizationRuntimeAssetContract {
    public static let frameworkVersion = "0.35.0"
    public static let frameworkRevision = "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b"

    public static let initImageManifestDigest =
        "b3b054594e1b3bf6a21683f2a26074ceff73409ac538b86b2e9513e849d9b325"
    public static let initImageManifestSize: Int64 = 406
    public static let initImageConfigurationDigest =
        "d5ed2e2c7255c07724bb8a2eded642eb3a4f7a7d4b83441b7075f6682336738e"
    public static let initImageConfigurationSize: Int64 = 151
    public static let initImageLayerDigest =
        "ffd2251deae40a37b6ba2728ebd4e47edf3ef90a16c1149da28b1f0411d2980c"
    public static let initImageLayerSize: Int64 = 67_223_020
    public static let initImageIndexJSONSHA256 =
        "bef61a59416346b17767bd3b1f4dc340a5beb3bcfb3439489b4d8412b2cc3563"
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

import Foundation

public enum ContainerizationRuntimeAssetContract {
    public static let frameworkVersion = "0.35.0"
    public static let frameworkRevision = "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b"

    public static let initImageManifestDigest =
        "15a70c63c9ca254020d8bdbe1b6e48332db0629881f563624bfd319412a37ea3"
    public static let initImageManifestSize: Int64 = 406
    public static let initImageConfigurationDigest =
        "7812fb606774f30d8b6d36c2a37a6e12ae719ece3fc34775f9b87ee94639e257"
    public static let initImageConfigurationSize: Int64 = 151
    public static let initImageLayerDigest =
        "3c6b087fc41b30d44dac2951f0ee798b242fac8e00db9b6375e25ef48765418d"
    public static let initImageLayerSize: Int64 = 67_222_934
    public static let initImageIndexJSONSHA256 =
        "ca910ca52793fbd5269c98aff0ba03091238558ac087d47967611f9d033076d1"
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

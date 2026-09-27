import Foundation

public enum ContainerizationRuntimeAssetContract {
    public static let frameworkVersion = "0.35.0"
    public static let frameworkRevision = "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b"

    public static let initImageManifestDigest =
        "9b7d2e0d32dd662d6a40f7b25a35dc28b5267e932465403f31bf47723dafb0cd"
    public static let initImageManifestSize: Int64 = 406
    public static let initImageConfigurationDigest =
        "188cfff3bfe0bde342bb3e73ebc0f5d2fafa2f366bd78b68c391ccff4e3c12ae"
    public static let initImageConfigurationSize: Int64 = 151
    public static let initImageLayerDigest =
        "bd71734611fbccd656736610e8170546bf05d64e62a09895790364ea59818bfc"
    public static let initImageLayerSize: Int64 = 67_226_282
    public static let initImageIndexJSONSHA256 =
        "a5fb5845e3e9d96aba5789f3a65b776f7c007ac4b7d751f17077cf36d3c0e58e"
    public static let initImageIndexJSONSize: Int64 = 240
    public static let initImageLayoutSHA256 =
        "18f0797eab35a4597c1e9624aa4f15fd91f6254e5538c1e0d193b2a95dd4acc6"
    public static let initImageLayoutSize: Int64 = 30
    public static var initImageReference: String {
        "untagged@sha256:\(initImageManifestDigest)"
    }

    public static let kernelFileName = "vmlinux-6.18.15-186"
    public static let kernelSHA256 =
        "74b612335db14171de36bcc68fb82bbc19751e07bc440d4c1724ad92a08b4132"
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

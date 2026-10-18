import Foundation

public enum ContainerizationRuntimeAssetContract {
    public static let frameworkVersion = "0.35.0"
    public static let frameworkRevision = "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b"

    public static let initImageManifestDigest =
        "279d191a42539a5ad4e4e73f396d9356cbc7fc865e335bb85efd3b2588da1212"
    public static let initImageManifestSize: Int64 = 406
    public static let initImageImportedIndexSHA256 =
        "523d7e7ac9ee8475f91f29b1d5e215f4bfdcd98e7e2e2369bcca827a32d0bc80"
    public static let initImageImportedIndexSize: Int64 = 358
    public static let initImageConfigurationDigest =
        "c6decfc522bff7ccf321cde092127761fef4a34d5b07912fb8183304f13ac3ec"
    public static let initImageConfigurationSize: Int64 = 151
    public static let initImageLayerDigest =
        "5c64be872ab8404a80a6064adf6b0a717c5cdd7171036cf6f8ad27715b4c93e9"
    public static let initImageLayerSize: Int64 = 67_299_759
    public static let initImageIndexJSONSHA256 =
        "349ef898931e45eb5b447cfbbd52dc6421dee0a0eabfb8120b5b8c213996c5b2"
    public static let initImageIndexJSONSize: Int64 = 240
    public static let initImageLayoutSHA256 =
        "18f0797eab35a4597c1e9624aa4f15fd91f6254e5538c1e0d193b2a95dd4acc6"
    public static let initImageLayoutSize: Int64 = 30
    public static var initImageReference: String {
        "untagged@sha256:\(initImageManifestDigest)"
    }

    public static let kernelFileName = "vmlinux-6.18.55-186"
    public static let kernelSHA256 =
        "3dd936598c8e457d2c95e69fc987f8426d76671564d8f2ab658800c185f8c746"
    public static let kernelSize: Int64 = 16_216_576

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
        "sha256:\(initImageImportedIndexSHA256)"
    }

    public static var initImageVariantDigest: String {
        "sha256:\(initImageManifestDigest)"
    }
}

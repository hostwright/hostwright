import Foundation

public enum ContainerizationRuntimeAssetContract {
    public static let frameworkVersion = "0.35.0"
    public static let frameworkRevision = "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b"

    public static let initImageManifestDigest =
        "3a5094a64cdef4cf046d2c14c4ddcc7b90b9cb3770557448057963f3bf407ee6"
    public static let initImageManifestSize: Int64 = 406
    public static let initImageImportedIndexSHA256 =
        "192a6c09c051ff325dc287c74b7a0abd98ba9f8de774bf49cba668103b2f9ba8"
    public static let initImageImportedIndexSize: Int64 = 358
    public static let initImageConfigurationDigest =
        "3fb2ac47d7b42b5021eeb8df651ef59376d21a195ead7e6c06d165b033b01542"
    public static let initImageConfigurationSize: Int64 = 151
    public static let initImageLayerDigest =
        "2dfd62ec0dadc8639b0d9791290c7f7cbb5bf6c6c8be835a206146f8783b2de0"
    public static let initImageLayerSize: Int64 = 67_299_790
    public static let initImageIndexJSONSHA256 =
        "59846bfa4f0493957ef54a6fecb0d6d80a16f4613a277e7c4c3aaca34894526b"
    public static let initImageIndexJSONSize: Int64 = 240
    public static let initImageLayoutSHA256 =
        "18f0797eab35a4597c1e9624aa4f15fd91f6254e5538c1e0d193b2a95dd4acc6"
    public static let initImageLayoutSize: Int64 = 30
    public static var initImageReference: String {
        "untagged@sha256:\(initImageManifestDigest)"
    }

    public static let kernelFileName = "vmlinux-6.18.55-186"
    public static let kernelSHA256 =
        "f9f44ee7f47457dce364e494633d1056950f22301aeba1c8f01f665d958f3adf"
    public static let kernelSize: Int64 = 16_151_040

    public static let guestNetworkPolicyLoaderSHA256 =
        "eec0f5c4528f87cf89724474c48dc69fa1bec1511f42e06b3ad9e400b19a2fda"
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

import Foundation

public enum ContainerizationRuntimeAssetContract {
    public static let frameworkVersion = "0.35.0"
    public static let frameworkRevision = "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b"

    public static let initImageReference = "ghcr.io/apple/containerization/vminit:0.35.0"
    public static let initImageRegistryRepository = "apple/containerization/vminit"
    public static let initImageIndexDigest =
        "5708d65ba1914caa756a2e813831e17d7655042799310bc94efef82210c2dac6"
    public static let initImageVariantDigest =
        "04cd14f8e6ec9617611429aaf2a91a841b27ff9eae847acaca48430f58c5e57d"
    public static let initImageConfigurationDigest =
        "30d24816422f41337fae35f59a3c03ac13559fd42bd0d67321a7db4d57ac4988"
    public static let initImageLayerDigest =
        "e3b2b9d347c2e5834d9fe5b4d615f5c0632c485d785e64f5c6b4c9b179ac168f"
    public static let initImageIndexSize: Int64 = 306
    public static let initImageVariantSize: Int64 = 409
    public static let initImageConfigurationSize: Int64 = 255
    public static let initImageLayerSize: Int64 = 66_895_112

    public static let kernelFileName = "vmlinux-6.18.15-186"
    public static let kernelSHA256 =
        "2fe4a58d2885d623bcb4d705900ac8c1d4f02371152da8126b3b00c8c47fc3a1"
    public static let kernelSize: Int64 = 16_151_040
    public static let kernelArchiveURL =
        "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst"
    public static let kernelArchiveSHA256 =
        "f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91"
    public static let kernelArchiveSize: Int64 = 596_775_193
    public static let kernelArchiveMember =
        "opt/kata/share/kata-containers/vmlinux-6.18.15-186"

    public static let installationRelativeRoot = "share/hostwright/containerization"
    public static let kernelInstallationRelativePath =
        "\(installationRelativeRoot)/kernel/\(kernelFileName)"
    public static let initImageLayoutInstallationRelativePath =
        "\(installationRelativeRoot)/vminit"

    public static var initImageDescriptorDigest: String {
        "sha256:\(initImageIndexDigest)"
    }
}

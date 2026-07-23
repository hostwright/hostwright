import Foundation
@testable import HostwrightDistribution

func makeDistributionTestContainerizationAssets(
    at root: URL
) throws -> DistributionContainerizationAssetBundle {
    let assetRoot = root.appendingPathComponent(
        "containerization-assets-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: false)
    var files: [String: URL] = [:]
    for payloadPath in DistributionContainerizationAssets.payloadModes.keys.sorted() {
        let file = assetRoot.appendingPathComponent(payloadPath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test-asset:\(payloadPath)\n".utf8).write(
            to: file,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: file.path
        )
        files[payloadPath] = file
    }
    return DistributionContainerizationAssetBundle(validatedFilesByPayloadPath: files)
}

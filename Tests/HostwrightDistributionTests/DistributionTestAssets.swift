import Foundation
@testable import HostwrightDistribution

func makeDistributionTestContainerizationAssetRoot(
    at root: URL
) throws -> URL {
    let assetRoot = root.appendingPathComponent(
        "containerization-assets-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: assetRoot.path
    )
    for payloadPath in DistributionContainerizationAssets.payloadModes.keys.sorted() {
        guard let relativePath =
            DistributionContainerizationAssets
            .rootRelativePathsByPayloadPath[payloadPath] else {
            throw DistributionError.invalidArtifact(
                "Containerization asset test payload mapping is incomplete."
            )
        }
        let file = assetRoot.appendingPathComponent(
            relativePath,
            isDirectory: false
        )
        var current = assetRoot
        for component in file.pathComponents.dropFirst(assetRoot.pathComponents.count).dropLast() {
            current.appendPathComponent(component, isDirectory: true)
            if !FileManager.default.fileExists(atPath: current.path) {
                try FileManager.default.createDirectory(
                    at: current,
                    withIntermediateDirectories: false
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: current.path
            )
        }
        let data: Data
        if payloadPath ==
            DistributionContainerizationAssets
                .guestNetworkPolicyLoaderPayloadPath {
            var executable = Data(repeating: 0, count: 64)
            executable.replaceSubrange(
                0..<20,
                with: [
                    0x7f, 0x45, 0x4c, 0x46,
                    2, 1, 1, 0,
                    0, 0, 0, 0, 0, 0, 0, 0,
                    3, 0,
                    183, 0
                ]
            )
            data = executable
        } else {
            data = Data("test-asset:\(payloadPath)\n".utf8)
        }
        try data.write(
            to: file,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: file.path
        )
    }
    return assetRoot
}

func makeDistributionTestContainerizationAssets(
    at root: URL
) throws -> DistributionContainerizationAssetBundle {
    let assetRoot = try makeDistributionTestContainerizationAssetRoot(
        at: root
    )
    var files: [String: URL] = [:]
    for payloadPath in DistributionContainerizationAssets.payloadModes.keys.sorted() {
        guard let relativePath =
            DistributionContainerizationAssets
            .rootRelativePathsByPayloadPath[payloadPath] else {
            throw DistributionError.invalidArtifact(
                "Containerization asset test payload mapping is incomplete."
            )
        }
        let file = assetRoot.appendingPathComponent(
            relativePath,
            isDirectory: false
        )
        files[payloadPath] = file
    }
    return DistributionContainerizationAssetBundle(
        validatedFilesByPayloadPath: files
    )
}

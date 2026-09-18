import CryptoKit
import Darwin
import Foundation
import HostwrightCore

struct ThirdPartyLicenseDocument: Codable, Equatable {
    let sourcePath: String
    let category: String
    let offsetBytes: Int
    let sizeBytes: Int
    let sha256: String
    let sourcePaths: [String]
}

struct ThirdPartyLicenseDependency: Codable, Equatable {
    let identity: String
    let location: String
    let revision: String
    let version: String
    let rootLicenseExpression: String
    let documents: [ThirdPartyLicenseDocument]
}

struct ThirdPartyLicenseInventory: Codable, Equatable {
    let kind: String
    let schemaVersion: Int
    let resolvedSHA256: String
    let dependencyCount: Int
    let noticesSHA256: String
    let dependencies: [ThirdPartyLicenseDependency]
    let runtimeDocuments: [ThirdPartyLicenseDocument]
}

struct RuntimeLicenseDependency: Codable, Equatable {
    let identity: String
    let location: String
    let revision: String
    let version: String
}

struct RuntimeGoDependency: Codable, Equatable {
    let module: String
    let version: String
    let checksum: String
}

struct RuntimeLicenseAsset: Codable, Equatable {
    let identity: String
    let payloadPaths: [String]
    var sha256: String
    var sizeBytes: Int64
    let licenseExpression: String
    let status: String
    let sourceReferences: [String]
    let blockers: [String]
    let sourceDistributionEvidence: [String]
}

struct RuntimeKernelSourceEvidence: Codable, Equatable {
    let sourceArchiveURL: String
    let sourceArchiveSHA256: String
    let sourceArchiveSizeBytes: Int64
    let actualConfigurationSHA256: String
    let actualConfigurationSizeBytes: Int
    let configurationVersion: String
    let recipeRevision: String
    let compiler: String
    let linker: String
    let sourceDistributionRoute: String
}

struct RuntimeLicenseInventory: Codable, Equatable {
    let kind: String
    let schemaVersion: Int
    let status: String
    let frameworkVersion: String
    let frameworkRevision: String
    let noticesSHA256: String
    let kernelSourceEvidence: RuntimeKernelSourceEvidence
    let kernelArchiveURL: String
    let kernelArchiveSHA256: String
    let initImageReference: String
    let initImageConfigurationSHA256: String
    let initImageLayerSHA256: String
    let guestResolvedSHA256: String
    let guestDependencies: [RuntimeLicenseDependency]
    let goModuleSHA256: String
    let goSumSHA256: String
    let goVersion: String
    let goDependencies: [RuntimeGoDependency]
    let retainedLoaderSourceRevision: String
    let retainedLoaderSourceFiles: [String: String]
    let retainedLoaderBinarySHA256: String
    let retainedLoaderLinkedModules: [RuntimeGoDependency]
    let retainedLoaderBuildSettings: [String: String]
    var assets: [RuntimeLicenseAsset]
    var payloadFiles: [DistributionFileRecord]
}

enum DistributionThirdPartyNotices {
    static let noticesPath = "share/doc/hostwright/THIRD_PARTY_NOTICES"
    static let dependencyInventoryPath = "share/doc/hostwright/third-party-license-inventory.json"
    static let runtimeInventoryPath = "share/doc/hostwright/runtime-license-inventory.json"
    static let payloadModes = [noticesPath: 0o644, dependencyInventoryPath: 0o644, runtimeInventoryPath: 0o644]

    static func sourcePayload(
        root: URL,
        runtimeAssets: DistributionContainerizationAssetBundle
    ) throws -> [String: Data] {
        let notices = try read(root.appendingPathComponent("THIRD_PARTY_NOTICES"))
        let inventoryData = try read(root.appendingPathComponent("third-party-license-inventory.json"))
        let runtimeData = try read(root.appendingPathComponent("runtime-license-inventory.json"))
        let inventory = try decode(ThirdPartyLicenseInventory.self, data: inventoryData)
        var runtime = try decode(RuntimeLicenseInventory.self, data: runtimeData)
        try validate(notices: notices, inventory: inventory, runtime: runtime)
        let resolved = try read(root.appendingPathComponent("Package.resolved"))
        guard hash(resolved) == inventory.resolvedSHA256,
              let document = try JSONSerialization.jsonObject(with: resolved) as? [String: Any],
              let pins = document["pins"] as? [[String: Any]], pins.count == inventory.dependencies.count else {
            throw DistributionError.invalidArtifact("Third-party notices do not bind the exact resolved dependency graph.")
        }
        let expected = inventory.dependencies.map { "\($0.identity)|\($0.location)|\($0.revision)|\($0.version)" }.sorted()
        let observed = pins.compactMap { pin -> String? in
            guard let identity = pin["identity"] as? String, let location = pin["location"] as? String,
                  let state = pin["state"] as? [String: Any], let revision = state["revision"] as? String,
                  revision.count == 40 else { return nil }
            let version = state["version"] as? String ?? ""
            return "\(identity)|\(location)|\(revision)|\(version)"
        }.sorted()
        guard expected == observed else {
            throw DistributionError.invalidArtifact("Third-party license inventory has missing, extra, or changed dependency pins.")
        }
        let goModule = try read(root.appendingPathComponent("Guest/HostwrightNetfilter/go.mod"))
        let goSum = try read(root.appendingPathComponent("Guest/HostwrightNetfilter/go.sum"))
        guard hash(goModule) == runtime.goModuleSHA256, hash(goSum) == runtime.goSumSHA256,
              let sumText = String(data: goSum, encoding: .utf8),
              runtime.goDependencies.allSatisfy({
                  sumText.split(separator: "\n").contains(Substring("\($0.module) \($0.version) \($0.checksum)"))
              }) else {
            throw DistributionError.invalidArtifact("Guest Go inventory does not bind exact source module checksums.")
        }
        for (path, digest) in runtime.retainedLoaderSourceFiles {
            guard path.hasPrefix("Guest/HostwrightNetfilter/"), !path.contains(".."),
                  hash(try read(root.appendingPathComponent(path))) == digest else {
                throw DistributionError.invalidArtifact("Guest loader source differs from retained binary source inventory.")
            }
        }
        runtime.payloadFiles = try runtimeAssets.filesByPayloadPath.keys.sorted().map { path in
            let data = try read(runtimeAssets.filesByPayloadPath[path]!)
            return DistributionFileRecord(path: path, sha256: hash(data), sizeBytes: data.count,
                                           mode: DistributionContainerizationAssets.payloadModes[path]!)
        }
        guard let loader = runtime.payloadFiles.first(where: {
            $0.path == ContainerizationRuntimeAssetContract.guestNetworkPolicyLoaderInstallationRelativePath
        }) else { throw DistributionError.invalidArtifact("Runtime inventory lacks the shipped guest policy loader.") }
        runtime.assets[2].sha256 = loader.sha256
        runtime.assets[2].sizeBytes = Int64(loader.sizeBytes)
        return [noticesPath: notices, dependencyInventoryPath: inventoryData, runtimeInventoryPath: try encode(runtime)]
    }

    static func validatePayload(root: URL, files: [DistributionFileRecord], expectedDependencies: [String]? = nil, requireQualified: Bool = false) throws {
        let notices = try read(root.appendingPathComponent(noticesPath))
        let inventory = try decode(ThirdPartyLicenseInventory.self, data: read(root.appendingPathComponent(dependencyInventoryPath)))
        let runtime = try decode(RuntimeLicenseInventory.self, data: read(root.appendingPathComponent(runtimeInventoryPath)))
        try validate(notices: notices, inventory: inventory, runtime: runtime)
        if let expectedDependencies {
            let dependencies = inventory.dependencies.map { "\($0.identity)|\($0.location)|\($0.version)|\($0.revision)" }.sorted()
            guard dependencies == expectedDependencies else {
                throw DistributionError.invalidArtifact("Shipped license pins differ from authenticated build provenance.")
            }
        }
        if requireQualified { try requireQualifiedRuntime(runtime) }
        let expected = files.filter { DistributionContainerizationAssets.payloadModes[$0.path] != nil }
            .sorted { $0.path < $1.path }
        guard runtime.payloadFiles == expected,
              let loader = expected.first(where: {
                  $0.path == ContainerizationRuntimeAssetContract.guestNetworkPolicyLoaderInstallationRelativePath
              }), runtime.assets[2].sha256 == loader.sha256,
              runtime.assets[2].sizeBytes == Int64(loader.sizeBytes) else {
            throw DistributionError.invalidArtifact("Runtime license inventory does not bind the exact shipped runtime asset bytes.")
        }
    }

    static func requireQualifiedRuntimeSource(root: URL) throws {
        let runtime = try decode(RuntimeLicenseInventory.self, data: read(root.appendingPathComponent("runtime-license-inventory.json")))
        try requireQualifiedRuntime(runtime)
    }

    private static func requireQualifiedRuntime(_ runtime: RuntimeLicenseInventory) throws {
        guard runtime.status == "qualified", runtime.assets.allSatisfy({
            $0.status == "qualified" && $0.blockers.isEmpty && !$0.sourceDistributionEvidence.isEmpty &&
                !$0.licenseExpression.contains("Pending")
        }) else {
            throw DistributionError.invalidArtifact("Trusted release blocked: runtime corresponding-source, build provenance, or component-license evidence remains incomplete. See runtime-license-inventory.json.")
        }
    }

    static func validate(notices: Data, inventory: ThirdPartyLicenseInventory, runtime: RuntimeLicenseInventory) throws {
        guard inventory.kind == "hostwright.third-party-license-inventory.v1", inventory.schemaVersion == 1,
              inventory.dependencyCount == inventory.dependencies.count, !inventory.dependencies.isEmpty,
              inventory.dependencies.map(\.identity) == inventory.dependencies.map(\.identity).sorted(),
              Set(inventory.dependencies.map(\.identity)).count == inventory.dependencies.count,
              isHash(inventory.resolvedSHA256), inventory.noticesSHA256 == hash(notices),
              runtime.kind == "hostwright.runtime-license-inventory.v1", runtime.schemaVersion == 1,
              runtime.noticesSHA256 == inventory.noticesSHA256,
              runtime.frameworkVersion == ContainerizationRuntimeAssetContract.frameworkVersion,
              runtime.frameworkRevision == ContainerizationRuntimeAssetContract.frameworkRevision,
              runtime.kernelArchiveURL == ContainerizationRuntimeAssetContract.kernelArchiveURL,
              runtime.kernelArchiveSHA256 == ContainerizationRuntimeAssetContract.kernelArchiveSHA256,
              runtime.initImageReference == ContainerizationRuntimeAssetContract.initImageReference,
              runtime.initImageConfigurationSHA256 == ContainerizationRuntimeAssetContract.initImageConfigurationDigest,
              runtime.initImageLayerSHA256 == ContainerizationRuntimeAssetContract.initImageLayerDigest,
              isHash(runtime.guestResolvedSHA256), !runtime.guestDependencies.isEmpty,
              runtime.guestDependencies.map(\.identity) == runtime.guestDependencies.map(\.identity).sorted(),
              Set(runtime.guestDependencies.map(\.identity)).count == runtime.guestDependencies.count,
              isHash(runtime.goModuleSHA256), isHash(runtime.goSumSHA256), !runtime.goVersion.isEmpty,
              !runtime.goDependencies.isEmpty,
              runtime.goDependencies.map(\.module) == runtime.goDependencies.map(\.module).sorted(),
              Set(runtime.goDependencies.map(\.module)).count == runtime.goDependencies.count,
              runtime.assets.map(\.identity) == ["kata-linux-kernel", "apple-vminit-oci", "hostwright-netfilter-loader"],
              runtime.assets[0].sha256 == ContainerizationRuntimeAssetContract.kernelSHA256,
              runtime.assets[0].sizeBytes == ContainerizationRuntimeAssetContract.kernelSize,
              runtime.assets[1].sha256 == ContainerizationRuntimeAssetContract.initImageIndexDigest,
              runtime.assets[1].sizeBytes == ContainerizationRuntimeAssetContract.initImageIndexSize else {
            throw DistributionError.invalidArtifact("Third-party notices or runtime inventory have invalid pin, digest, or coverage bindings.")
        }
        guard runtime.retainedLoaderSourceFiles.count == 20, isHash(runtime.retainedLoaderBinarySHA256),
              runtime.retainedLoaderLinkedModules.count == 6,
              runtime.retainedLoaderLinkedModules.allSatisfy({ runtime.goDependencies.contains($0) }),
              runtime.retainedLoaderBuildSettings["CGO_ENABLED"] == "0",
              runtime.retainedLoaderBuildSettings["GOARCH"] == "arm64",
              runtime.retainedLoaderBuildSettings["GOOS"] == "linux" else {
            throw DistributionError.invalidArtifact("Retained loader binary inventory is incomplete or inconsistent.")
        }
        guard runtime.kernelSourceEvidence.configurationVersion == "186",
              isHash(runtime.kernelSourceEvidence.sourceArchiveSHA256),
              isHash(runtime.kernelSourceEvidence.actualConfigurationSHA256),
              inventory.runtimeDocuments.contains(where: {
                  $0.sourcePath == "runtime-build-recipe/kernel-actual-config-6.18.15-186" &&
                  $0.sha256 == runtime.kernelSourceEvidence.actualConfigurationSHA256 &&
                  $0.sizeBytes == runtime.kernelSourceEvidence.actualConfigurationSizeBytes
              }) else {
            throw DistributionError.invalidArtifact("Kernel corresponding-source configuration binding is incomplete.")
        }
        for dependency in runtime.guestDependencies {
            guard dependency.revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                  inventory.runtimeDocuments.contains(where: {
                      $0.category == "runtime-guest-license" &&
                          $0.sourcePath.hasPrefix("guest-swift/\(dependency.identity)@\(dependency.revision)/")
                  }) else {
                throw DistributionError.invalidArtifact("A guest dependency lacks its exact pinned license text.")
            }
        }
        for dependency in inventory.dependencies {
            guard dependency.revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                  dependency.location.hasPrefix("https://github.com/"),
                  ["Apache-2.0", "MIT", "(BSD-3-Clause OR GPL-2.0-only)"].contains(dependency.rootLicenseExpression),
                  dependency.documents.contains(where: { $0.category == "root-license" }) else {
                throw DistributionError.invalidArtifact("A resolved dependency lacks its pinned root license text.")
            }
        }
        for document in inventory.dependencies.flatMap(\.documents) + inventory.runtimeDocuments {
            guard !document.sourcePath.isEmpty, !document.sourcePaths.isEmpty,
                  document.offsetBytes >= 0, document.sizeBytes > 0,
                  document.offsetBytes <= notices.count, document.sizeBytes <= notices.count - document.offsetBytes,
                  hash(notices.subdata(in: document.offsetBytes..<(document.offsetBytes + document.sizeBytes))) == document.sha256 else {
                throw DistributionError.invalidArtifact("A third-party license or attribution text is missing or changed.")
            }
        }
    }

    static func read(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DistributionError.invalidArtifact("Third-party inventory input is missing, unsafe, or oversized.")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0, before.st_size <= 128 * 1_024 * 1_024 else {
            throw DistributionError.invalidArtifact("Third-party inventory input is missing, unsafe, or oversized.")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result.count < before.st_size {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, min($0.count, Int(before.st_size) - result.count)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw DistributionError.invalidArtifact("Third-party input changed during read.") }
            result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino,
              named.st_mode & S_IFMT == S_IFREG else {
            throw DistributionError.invalidArtifact("Third-party input was modified or replaced during read.")
        }
        return result
    }

    static func decode<T: Codable>(_ type: T.Type, data: Data) throws -> T {
        let value = try JSONDecoder().decode(type, from: data)
        guard try encode(value) == data else {
            throw DistributionError.invalidArtifact("Third-party inventory must use its exact compact sorted schema encoding.")
        }
        return value
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isHash(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}

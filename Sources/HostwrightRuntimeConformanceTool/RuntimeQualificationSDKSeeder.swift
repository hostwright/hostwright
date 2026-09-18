import Containerization
import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import Security

/// Qualification preparation only. This never contacts a helper or starts a VM.
enum RuntimeQualificationSDKSeeder {
    struct Options {
        let config: URL
        let configDigest: String
        let layout: URL
        let layoutDigest: String
        let reference: String
        let descriptorDigest: String
        let variantDigest: String
    }

    static func parse(_ arguments: [String]) throws -> Options {
        let keys = Set(["--config", "--config-sha256", "--layout", "--layout-sha256", "--reference", "--descriptor", "--variant"])
        var values: [String: String] = [:]
        guard arguments.count == keys.count * 2 else { throw RuntimeQualificationCommandError.usage("sdk-seed requires exact config/layout hashes, reference, descriptor and variant") }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard keys.contains(arguments[index]), values[arguments[index]] == nil else { throw RuntimeQualificationCommandError.usage("duplicate or unknown sdk-seed argument") }
            values[arguments[index]] = arguments[index + 1]
        }
        let options = Options(config: URL(fileURLWithPath: values["--config"]!), configDigest: values["--config-sha256"]!,
            layout: URL(fileURLWithPath: values["--layout"]!, isDirectory: true), layoutDigest: values["--layout-sha256"]!,
            reference: values["--reference"]!, descriptorDigest: values["--descriptor"]!, variantDigest: values["--variant"]!)
        guard values["--config"]!.hasPrefix("/"), values["--layout"]!.hasPrefix("/"),
              validDigest(options.configDigest), validDigest(options.layoutDigest),
              options.descriptorDigest.hasPrefix("sha256:"), validDigest(String(options.descriptorDigest.dropFirst(7))),
              options.variantDigest.hasPrefix("sha256:"), validDigest(String(options.variantDigest.dropFirst(7))),
              !options.reference.isEmpty else { throw RuntimeQualificationCommandError.usage("invalid sdk-seed binding") }
        return options
    }

    static func run(arguments: [String]) async -> RuntimeQualificationCommandResult {
        do {
            let options = try parse(arguments)
            let configurationData = try readSafe(options.config, privateFile: true)
            guard digest(configurationData) == options.configDigest,
                  let config = try JSONSerialization.jsonObject(with: configurationData) as? [String: Any],
                  config["schema"] as? Int == 1, config["framework"] as? String == ContainerizationRuntimeAssetContract.frameworkVersion,
                  config["initImageReference"] as? String == ContainerizationRuntimeAssetContract.initImageReference,
                  config["initImageDescriptorDigest"] as? String == "sha256:" + ContainerizationRuntimeAssetContract.initImageIndexDigest,
                  config["initImageVariantDigest"] as? String == "sha256:" + ContainerizationRuntimeAssetContract.initImageVariantDigest,
                  let rootPath = config["dataRootPath"] as? String,
                  let runtimePath = config["runtimeDirectoryPath"] as? String,
                  let kernelPath = config["kernelPath"] as? String,
                  let kernelDigest = config["kernelSHA256"] as? String,
                  let initPath = config["initImageLayoutPath"] as? String else { throw RuntimeQualificationCommandError.blocked("SDK configuration binding/schema/framework mismatch") }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            let runtime = URL(fileURLWithPath: runtimePath, isDirectory: true)
            try safeAncestry(root, allowMissingLeaf: true)
            try safeAncestry(runtime, allowMissingLeaf: true)
            try safeAncestry(options.layout, allowMissingLeaf: false)
            guard rootPath.hasPrefix("/"), runtimePath.hasPrefix("/"),
                  !FileManager.default.fileExists(atPath: root.path), root.path != "/",
                  !overlap(root, runtime), !overlap(root, options.layout), !overlap(root, options.config),
                  !overlap(root, URL(fileURLWithPath: initPath, isDirectory: true)),
                  !overlap(root, URL(fileURLWithPath: kernelPath)),
                  kernelDigest == ContainerizationRuntimeAssetContract.kernelSHA256,
                  digest(try readSafe(URL(fileURLWithPath: kernelPath))) == kernelDigest else {
                throw RuntimeQualificationCommandError.blocked("SDK seed root exists, overlaps inputs/runtime, or kernel binding changed")
            }
            let initRoot = URL(fileURLWithPath: initPath, isDirectory: true)
            for expected in [ContainerizationRuntimeAssetContract.initImageIndexDigest,
                             ContainerizationRuntimeAssetContract.initImageVariantDigest,
                             ContainerizationRuntimeAssetContract.initImageConfigurationDigest,
                             ContainerizationRuntimeAssetContract.initImageLayerDigest] {
                guard digest(try readSafe(initRoot.appendingPathComponent("blobs/sha256/" + expected))) == expected else {
                    throw RuntimeQualificationCommandError.blocked("SDK init image blob binding mismatch")
                }
            }
            var parentMetadata = stat()
            guard lstat(root.deletingLastPathComponent().path, &parentMetadata) == 0,
                  parentMetadata.st_uid == geteuid(), parentMetadata.st_mode & 0o7777 == 0o700 else {
                throw RuntimeQualificationCommandError.blocked("SDK seed direct parent must be private and owned")
            }
            let treeDigest = try layoutDigest(options.layout)
            guard treeDigest == options.layoutDigest else { throw RuntimeQualificationCommandError.blocked("SDK OCI tree digest mismatch") }
            let executable = try SecureExecutableResolver.verify(path: "/usr/bin/pgrep", ownershipPolicy: .rootOnly)
            try validateProcessInventoryCode(processID: nil)
            let processes = try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: "/usr/bin/pgrep", arguments: ["-af", #"(^|/)hostwright-containerization-helper([[:space:]]|$)"#],
                    environment: SecureSubprocessEnvironment.minimal, workingDirectory: "/",
                    timeoutMilliseconds: 5_000, terminationGraceMilliseconds: 100,
                    maximumStandardOutputBytes: 2 * 1_024 * 1_024, maximumStandardErrorBytes: 64 * 1_024
                ),
                expectedExecutable: executable,
                suspendedProcessValidator: { try validateProcessInventoryCode(processID: $0) }
            )
            try validateHelperAbsence(processes)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let images = root.appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let store = try ImageStore(path: images)
            let imported = try await store.load(from: options.layout)
            guard imported.count == 1, let image = imported.first,
                  image.reference == options.reference, image.descriptor.digest == options.descriptorDigest,
                  try await image.descriptor(for: .current).digest == options.variantDigest,
                  digest(try readSafe(options.config, privateFile: true)) == options.configDigest,
                  try layoutDigest(options.layout) == treeDigest else {
                throw RuntimeQualificationCommandError.failed("SDK imported image identity/input binding mismatch; fresh root retained for diagnosis")
            }
            let report: [String: Any] = ["kind": "hostwright.sdk-seed.v1", "framework": "0.35.0", "frameworkRevision": ContainerizationRuntimeAssetContract.frameworkRevision, "dataRootPath": root.path,
                "configurationSHA256": options.configDigest, "OCITreeSHA256": treeDigest,
                "reference": image.reference, "descriptorDigest": image.descriptor.digest, "variantDigest": options.variantDigest]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            return .success(String(decoding: data, as: UTF8.self) + "\n")
        } catch let error as RuntimeQualificationCommandError {
            return .failure(error.message, exitCode: error.exitCode)
        } catch { return .failure("SDK seed failed: \(error)", exitCode: 70) }
    }

    static func validateHelperAbsence(_ result: SecureSubprocessResult) throws {
        guard result.exitStatus == 1, result.terminationSignal == nil,
              !result.standardOutputTruncated, !result.standardErrorTruncated,
              result.standardOutput.isEmpty, result.standardError.isEmpty else {
            throw RuntimeQualificationCommandError.blocked("a Containerization helper is running or process inventory failed")
        }
    }

    private static func validateProcessInventoryCode(processID: pid_t?) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            #"anchor apple and identifier "com.apple.pkill""# as CFString, [], &requirement
        ) == errSecSuccess, let requirement else {
            throw RuntimeQualificationCommandError.blocked("system process inventory code requirement unavailable")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate)
        let status: OSStatus
        if let processID {
            var code: SecCode?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
                throw RuntimeQualificationCommandError.blocked("system process inventory peer identity unavailable")
            }
            status = SecCodeCheckValidity(code, flags, requirement)
        } else {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/pgrep") as CFURL, [], &code) == errSecSuccess, let code else {
                throw RuntimeQualificationCommandError.blocked("system process inventory executable identity unavailable")
            }
            status = SecStaticCodeCheckValidity(code, flags, requirement)
        }
        guard status == errSecSuccess else {
            throw RuntimeQualificationCommandError.blocked("system process inventory code identity rejected")
        }
    }

    static func validDigest(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func overlap(_ lhs: URL, _ rhs: URL) -> Bool { lhs.path == rhs.path || lhs.path.hasPrefix(rhs.path + "/") || rhs.path.hasPrefix(lhs.path + "/") }

    static func safeAncestry(_ url: URL, allowMissingLeaf: Bool) throws {
        guard url.path.hasPrefix("/"), NSString(string: url.path).standardizingPath == url.path,
              !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw RuntimeQualificationCommandError.blocked("unsafe SDK seed path") }
        var current = url
        var first = true
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard first && allowMissingLeaf && errno == ENOENT else { throw RuntimeQualificationCommandError.blocked("missing/unsafe SDK seed ancestry") }
            } else {
                guard info.st_mode & S_IFMT != S_IFLNK,
                      info.st_uid == geteuid() || info.st_uid == 0,
                      info.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else { throw RuntimeQualificationCommandError.blocked("untrusted SDK seed ancestry") }
            }
            first = false; current.deleteLastPathComponent()
        }
    }

    static func readSafe(_ url: URL, privateFile: Bool = false) throws -> Data {
        try safeAncestry(url, allowMissingLeaf: false)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RuntimeQualificationCommandError.blocked("SDK bound file unavailable") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 1_073_741_824,
              !privateFile || (info.st_uid == geteuid() && info.st_mode & 0o7777 == 0o600) else { throw RuntimeQualificationCommandError.blocked("unsafe SDK bound file") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.readToEnd() ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, info.st_ino == after.st_ino, info.st_size == after.st_size,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              bytes.count == Int(info.st_size) else { throw RuntimeQualificationCommandError.blocked("SDK bound file changed while reading") }
        return bytes
    }

    /// SHA256 of sorted UTF8 `relativePath + NUL + contentSHA256 + newline`.
    static func layoutDigest(_ root: URL) throws -> String {
        var enumerationFailed = false
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw RuntimeQualificationCommandError.blocked("OCI enumeration unavailable") }
        var files: [(String, String)] = []
        for case let url as URL in entries {
            try safeAncestry(url, allowMissingLeaf: false)
            var info = stat(); guard lstat(url.path, &info) == 0 else { throw RuntimeQualificationCommandError.blocked("OCI metadata unavailable") }
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let hash = digest(try readSafe(url))
            if relative.hasPrefix("blobs/sha256/") && relative != "blobs/sha256/" + hash { throw RuntimeQualificationCommandError.blocked("OCI blob digest/name mismatch") }
            files.append((relative, hash))
        }
        guard !enumerationFailed, files.contains(where: { $0.0 == "oci-layout" }), files.contains(where: { $0.0 == "index.json" }), files.count <= 10_000 else { throw RuntimeQualificationCommandError.blocked("invalid OCI layout") }
        return digest(Data(files.sorted { $0.0 < $1.0 }.map { $0.0 + "\0" + $0.1 + "\n" }.joined().utf8))
    }
}

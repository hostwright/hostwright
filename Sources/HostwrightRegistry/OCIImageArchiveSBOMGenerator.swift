import CryptoKit
import Darwin
import Foundation
import HostwrightCore

public struct OCIImageArchiveInventory: Equatable, Sendable {
    public let subjectDescriptor: OCIContentDescriptor
    public let imageManifestDescriptor: OCIContentDescriptor
    public let layers: [OCIContentDescriptor]
    public let operatingSystem: String?
    public let architecture: String?
    public let packages: [ImageSBOMComponent]
}

public struct GeneratedImageSBOM: Equatable, Sendable {
    public let format: ImageSBOMFormat
    public let payload: Data
    public let inventory: OCIImageArchiveInventory
}

public struct OCIImageArchiveSBOMGenerator: Sendable {
    public static let maximumArchiveBytes: Int64 = 16 * 1_024 * 1_024 * 1_024
    public static let maximumArchiveEntries = 32_768
    public static let maximumLayers = 512
    public static let maximumPackageDatabaseBytes = 16 * 1_024 * 1_024

    public init() {}

    public func inspect(
        archivePath: String,
        expectedSubjectDigest: OCIContentDigest,
        cancellation: SecureSubprocessCancellation =
            SecureSubprocessCancellation()
    ) throws -> OCIImageArchiveInventory {
        try checkCancellation(cancellation)
        let archive = try SecureTarArchive(
            path: archivePath,
            cancellation: cancellation
        )
        defer { archive.close() }
        let indexData = try archive.read(
            "index.json",
            maximumBytes: OCIReferrerLimits.maximumObjectBytes
        )
        let index = try parseIndex(indexData)
        let roots = index.filter {
            $0.digest == expectedSubjectDigest
        }
        guard roots.count == 1, let subjectDescriptor = roots.first else {
            throw ImageSBOMError.subjectDigestMismatch
        }
        var visited = Set<OCIContentDigest>()
        var matches: [(
            manifest: OCIContentDescriptor,
            config: OCIContentDescriptor,
            layers: [OCIContentDescriptor],
            os: String?,
            architecture: String?
        )] = []
        try visit(
            subjectDescriptor,
            archive: archive,
            depth: 0,
            visited: &visited,
            matches: &matches
        )
        let grouped = Dictionary(
            grouping: matches,
            by: { $0.manifest.digest.canonicalValue }
        )
        guard grouped.values.allSatisfy({ values in
            guard let first = values.first else { return false }
            return values.allSatisfy {
                $0.config == first.config &&
                    $0.layers == first.layers
            }
        }) else {
            throw ImageSBOMError.invalidDocument
        }
        let distinct = grouped.values.compactMap(\.first).sorted {
            $0.manifest.digest.canonicalValue <
                $1.manifest.digest.canonicalValue
        }
        guard !distinct.isEmpty else {
            throw ImageSBOMError.subjectDigestMismatch
        }
        let allLayers = distinct.flatMap(\.layers)
        guard allLayers.count <= Self.maximumLayers else {
            throw ImageSBOMError.limitExceeded
        }
        var packagesByID: [String: ImageSBOMComponent] = [:]
        for match in distinct {
            try checkCancellation(cancellation)
            try archive.verifyBlob(match.config)
            for layer in match.layers {
                try checkCancellation(cancellation)
                try archive.verifyBlob(layer)
            }
            for package in try scanPackages(
                layers: match.layers,
                archive: archive
            ) {
                if let existing = packagesByID[package.id],
                   existing != package {
                    throw ImageSBOMError.duplicateComponent
                }
                packagesByID[package.id] = package
            }
        }
        let operatingSystems = Set(distinct.compactMap(\.os))
        let architectures = Set(
            distinct.compactMap(\.architecture)
        )
        return OCIImageArchiveInventory(
            subjectDescriptor: subjectDescriptor,
            imageManifestDescriptor:
                distinct.count == 1
                    ? distinct[0].manifest
                    : subjectDescriptor,
            layers: allLayers,
            operatingSystem:
                operatingSystems.count == 1
                    ? operatingSystems.first
                    : nil,
            architecture:
                architectures.count == 1
                    ? architectures.first
                    : nil,
            packages: packagesByID.values.sorted {
                $0.id < $1.id
            }
        )
    }

    public func generate(
        archivePath: String,
        expectedSubjectDigest: OCIContentDigest,
        format: ImageSBOMFormat,
        createdAt: String,
        cancellation: SecureSubprocessCancellation =
            SecureSubprocessCancellation()
    ) throws -> GeneratedImageSBOM {
        try checkCancellation(cancellation)
        guard Self.validTimestamp(createdAt) else {
            throw ImageSBOMError.invalidDocument
        }
        let inventory = try inspect(
            archivePath: archivePath,
            expectedSubjectDigest: expectedSubjectDigest,
            cancellation: cancellation
        )
        try checkCancellation(cancellation)
        let payload: Data
        switch format {
        case .spdxJSON:
            payload = try spdx(
                inventory: inventory,
                createdAt: createdAt
            )
        case .cyclonedxJSON:
            payload = try cycloneDX(
                inventory: inventory,
                createdAt: createdAt
            )
        }
        _ = try ImageSBOMDocument.parse(
            payload,
            expectedSubjectDigest: expectedSubjectDigest,
            expectedFormat: format
        )
        return GeneratedImageSBOM(
            format: format,
            payload: payload,
            inventory: inventory
        )
    }

    private func checkCancellation(
        _ cancellation: SecureSubprocessCancellation
    ) throws {
        if cancellation.isCancelled {
            throw ImageSBOMError.cancelled
        }
    }

    private func visit(
        _ descriptor: OCIContentDescriptor,
        archive: SecureTarArchive,
        depth: Int,
        visited: inout Set<OCIContentDigest>,
        matches: inout [(
            manifest: OCIContentDescriptor,
            config: OCIContentDescriptor,
            layers: [OCIContentDescriptor],
            os: String?,
            architecture: String?
        )]
    ) throws {
        guard depth <= 4 else {
            throw ImageSBOMError.invalidDocument
        }
        guard visited.insert(descriptor.digest).inserted else {
            return
        }
        let data = try archive.readBlob(
            descriptor,
            maximumBytes: OCIReferrerLimits.maximumObjectBytes
        )
        let parsed: OCIParsedDocument
        do {
            parsed = try OCIParsedDocument.parse(data)
        } catch {
            throw ImageSBOMError.invalidDocument
        }
        switch parsed.kind {
        case .index:
            for child in parsed.children {
                try visit(
                    child,
                    archive: archive,
                    depth: depth + 1,
                    visited: &visited,
                    matches: &matches
                )
            }
        case .manifest:
            guard parsed.subject == nil,
                  let config = parsed.children.first,
                  Self.imageConfigurationMediaTypes.contains(
                      config.mediaType
                  ) else {
                return
            }
            let metadata = try imageConfiguration(
                archive.readBlob(
                    config,
                    maximumBytes:
                        OCIReferrerLimits.maximumObjectBytes
                )
            )
            guard metadata.operatingSystem != nil,
                  metadata.architecture != nil else {
                throw ImageSBOMError.invalidDocument
            }
            matches.append(
                (
                    manifest: descriptor,
                    config: config,
                    layers: Array(parsed.children.dropFirst()),
                    os: metadata.operatingSystem,
                    architecture: metadata.architecture
                )
            )
        case .blob:
            throw ImageSBOMError.invalidDocument
        }
    }

    private func parseIndex(
        _ data: Data
    ) throws -> [OCIContentDescriptor] {
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes: OCIReferrerLimits.maximumObjectBytes,
                allowedKeys: [
                    "schemaVersion", "mediaType", "manifests",
                    "annotations"
                ],
                requiredKeys: ["schemaVersion", "manifests"]
            )
        } catch {
            throw ImageSBOMError.invalidDocument
        }
        guard RegistryStrictJSONObject.integer(
            object["schemaVersion"]
        ) == 2,
        let raw = object["manifests"] as? [Any],
        !raw.isEmpty,
        raw.count <= Self.maximumLayers else {
            throw ImageSBOMError.invalidDocument
        }
        return try raw.map(parseDescriptor)
    }

    private func parseDescriptor(
        _ raw: Any
    ) throws -> OCIContentDescriptor {
        guard let object = raw as? [String: Any],
              let mediaType = object["mediaType"] as? String,
              let digest = object["digest"] as? String,
              let size = RegistryStrictJSONObject.integer(
                  object["size"]
              ) else {
            throw ImageSBOMError.invalidDocument
        }
        return try OCIContentDescriptor(
            mediaType: mediaType,
            digest: OCIContentDigest(digest),
            size: size
        )
    }

    private func imageConfiguration(
        _ data: Data
    ) throws -> (operatingSystem: String?, architecture: String?) {
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes: OCIReferrerLimits.maximumObjectBytes
            )
        } catch {
            throw ImageSBOMError.invalidDocument
        }
        let operatingSystem = object["os"] as? String
        let architecture = object["architecture"] as? String
        for value in [operatingSystem, architecture].compactMap({
            $0
        }) {
            guard !value.isEmpty,
                  value.utf8.count <= 64,
                  value.range(
                      of: "^[a-z0-9][a-z0-9._-]{0,63}$",
                      options: .regularExpression
                  ) != nil else {
                throw ImageSBOMError.invalidDocument
            }
        }
        return (operatingSystem, architecture)
    }

    private func scanPackages(
        layers: [OCIContentDescriptor],
        archive: SecureTarArchive
    ) throws -> [ImageSBOMComponent] {
        var latestAlpine: Data?
        var latestDebian: Data?
        for layer in layers {
            let packageDatabases = try archive.packageDatabases(
                in: layer,
                maximumOutputBytes:
                    Self.maximumPackageDatabaseBytes
            )
            if let alpine = packageDatabases.alpine {
                latestAlpine = alpine
            }
            if let debian = packageDatabases.debian {
                latestDebian = debian
            }
        }
        var packages: [ImageSBOMComponent] = []
        if let latestAlpine {
            packages += try parseAlpine(latestAlpine)
        }
        if let latestDebian {
            packages += try parseDebian(latestDebian)
        }
        guard packages.count <= ImageSBOMLimits.maximumComponents else {
            throw ImageSBOMError.limitExceeded
        }
        let byID = Dictionary(
            packages.map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first == second ? first : second
            }
        )
        guard byID.count == packages.count else {
            throw ImageSBOMError.duplicateComponent
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private func parseAlpine(
        _ data: Data
    ) throws -> [ImageSBOMComponent] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImageSBOMError.invalidDocument
        }
        return try text.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { block in
                var fields: [String: String] = [:]
                for line in block.split(separator: "\n") {
                    guard line.count >= 2, line[line.index(after: line.startIndex)] == ":" else {
                        continue
                    }
                    fields[String(line.prefix(1))] =
                        String(line.dropFirst(2))
                }
                guard let name = fields["P"],
                      let version = fields["V"] else {
                    throw ImageSBOMError.invalidComponent
                }
                return try ImageSBOMComponent(
                    id: "pkg:apk/\(name)@\(version)",
                    name: name,
                    version: version,
                    packageURL: "pkg:apk/\(name)@\(version)",
                    licenses: fields["L"].map { [$0] } ?? [],
                    hashes: [:]
                )
            }
    }

    private func parseDebian(
        _ data: Data
    ) throws -> [ImageSBOMComponent] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImageSBOMError.invalidDocument
        }
        return try text.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { block in
                var fields: [String: String] = [:]
                for line in block.split(separator: "\n")
                    where !line.hasPrefix(" ") {
                    guard let separator = line.firstIndex(of: ":") else {
                        continue
                    }
                    fields[String(line[..<separator])] =
                        String(line[line.index(after: separator)...])
                            .trimmingCharacters(in: .whitespaces)
                }
                guard let name = fields["Package"],
                      let version = fields["Version"] else {
                    throw ImageSBOMError.invalidComponent
                }
                let architecture = fields["Architecture"]
                let qualifier = architecture.map {
                    "?arch=\($0)"
                } ?? ""
                return try ImageSBOMComponent(
                    id: "pkg:deb/\(name)@\(version)\(qualifier)",
                    name: name,
                    version: version,
                    packageURL:
                        "pkg:deb/\(name)@\(version)\(qualifier)",
                    licenses: [],
                    hashes: [:]
                )
            }
    }

    private func spdx(
        inventory: OCIImageArchiveInventory,
        createdAt: String
    ) throws -> Data {
        let subject = inventory.subjectDescriptor.digest
        let rootID = "SPDXRef-Image"
        let packageObjects: [[String: Any]] = [[
            "name": "oci-image",
            "SPDXID": rootID,
            "versionInfo": String(subject.encoded.prefix(16)),
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": false,
            "checksums": [[
                "algorithm": subject.algorithm.uppercased(),
                "checksumValue": subject.encoded
            ]],
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION"
        ]] + inventory.packages.enumerated().map { index, component in
            var value: [String: Any] = [
                "name": component.name,
                "SPDXID": "SPDXRef-Package-\(index + 1)",
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": false,
                "licenseConcluded":
                    component.licenses.first ?? "NOASSERTION",
                "licenseDeclared":
                    component.licenses.first ?? "NOASSERTION",
                "copyrightText": "NOASSERTION",
                "externalRefs": component.packageURL.map {
                    [[
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": $0
                    ]]
                } ?? []
            ]
            if let version = component.version {
                value["versionInfo"] = version
            }
            return value
        }
        let relationships: [[String: Any]] = [[
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": rootID
        ]] + inventory.packages.indices.map { index in
            [
                "spdxElementId": rootID,
                "relationshipType": "CONTAINS",
                "relatedSpdxElement":
                    "SPDXRef-Package-\(index + 1)"
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "spdxVersion": "SPDX-2.3",
                "dataLicense": "CC0-1.0",
                "SPDXID": "SPDXRef-DOCUMENT",
                "name": "Hostwright OCI image SBOM",
                "documentNamespace":
                    "urn:hostwright:image-sbom:\(subject.encoded)",
                "creationInfo": [
                    "created": createdAt,
                    "creators": ["Tool: hostwright-0.0.2"]
                ],
                "packages": packageObjects,
                "relationships": relationships
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func cycloneDX(
        inventory: OCIImageArchiveInventory,
        createdAt: String
    ) throws -> Data {
        let subject = inventory.subjectDescriptor.digest
        let children: [[String: Any]] =
            inventory.packages.map { component in
                var value: [String: Any] = [
                    "type": "library",
                    "bom-ref": component.id,
                    "name": component.name,
                    "licenses": component.licenses.map {
                        ["license": ["id": $0]]
                    }
                ]
                if let version = component.version {
                    value["version"] = version
                }
                if let packageURL = component.packageURL {
                    value["purl"] = packageURL
                }
                return value
            }
        var root: [String: Any] = [
            "type": "container",
            "bom-ref": "oci-image@\(subject.canonicalValue)",
            "name": "oci-image",
            "version": String(subject.encoded.prefix(16)),
            "hashes": [[
                "alg": subject.algorithm == "sha256"
                    ? "SHA-256" : "SHA-512",
                "content": subject.encoded
            ]]
        ]
        if !children.isEmpty {
            root["components"] = children
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "bomFormat": "CycloneDX",
                "specVersion": "1.6",
                "serialNumber":
                    "urn:uuid:\(stableUUID(subject.encoded))",
                "version": 1,
                "metadata": [
                    "timestamp": createdAt,
                    "tools": [["name": "hostwright", "version": "0.0.2"]],
                    "component": root
                ],
                "components": children
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func stableUUID(_ digest: String) -> String {
        let hex = String(digest.prefix(32))
        return [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            "4" + String(hex.dropFirst(13).prefix(3)),
            "8" + String(hex.dropFirst(17).prefix(3)),
            String(hex.dropFirst(20).prefix(12))
        ].joined(separator: "-")
    }

    private static func validTimestamp(_ value: String) -> Bool {
        ISO8601DateFormatter().date(from: value) != nil &&
            value.utf8.count <= 64
    }

    private static let imageConfigurationMediaTypes = Set([
        "application/vnd.oci.image.config.v1+json",
        "application/vnd.docker.container.image.v1+json"
    ])
}

private final class SecureTarArchive {
    struct Entry {
        let offset: Int64
        let size: Int64
    }

    private let descriptor: Int32
    private let fileSize: Int64
    private let cancellation: SecureSubprocessCancellation
    private var entries: [String: Entry] = [:]

    init(
        path: String,
        cancellation: SecureSubprocessCancellation
    ) throws {
        self.cancellation = cancellation
        descriptor = Darwin.open(
            path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ImageSBOMError.invalidDocument
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == getuid() || metadata.st_uid == 0,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_size > 0,
              metadata.st_size <=
                OCIImageArchiveSBOMGenerator.maximumArchiveBytes else {
            Darwin.close(descriptor)
            throw ImageSBOMError.invalidDocument
        }
        fileSize = metadata.st_size
        do {
            try index()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func close() {
        Darwin.close(descriptor)
    }

    func read(
        _ path: String,
        maximumBytes: Int
    ) throws -> Data {
        guard let entry = entries[path],
              entry.size <= maximumBytes else {
            throw ImageSBOMError.limitExceeded
        }
        return try read(offset: entry.offset, count: Int(entry.size))
    }

    func readBlob(
        _ content: OCIContentDescriptor,
        maximumBytes: Int
    ) throws -> Data {
        let path = "blobs/\(content.digest.algorithm)/" +
            content.digest.encoded
        let data = try read(path, maximumBytes: maximumBytes)
        guard data.count == content.size,
              try content.digest.matches(data) else {
            throw ImageSBOMError.invalidDocument
        }
        return data
    }

    func verifyBlob(_ content: OCIContentDescriptor) throws {
        let path = "blobs/\(content.digest.algorithm)/" +
            content.digest.encoded
        guard let entry = entries[path],
              entry.size == content.size else {
            throw ImageSBOMError.invalidDocument
        }
        var offset = entry.offset
        var remaining = entry.size
        switch content.digest.algorithm {
        case "sha256":
            var hash = SHA256()
            while remaining > 0 {
                let count = Int(min(remaining, 64 * 1_024))
                let data = try read(offset: offset, count: count)
                hash.update(data: data)
                offset += Int64(count)
                remaining -= Int64(count)
            }
            let value = hash.finalize().map {
                String(format: "%02x", $0)
            }.joined()
            guard value == content.digest.encoded else {
                throw ImageSBOMError.invalidDocument
            }
        case "sha512":
            var hash = SHA512()
            while remaining > 0 {
                let count = Int(min(remaining, 64 * 1_024))
                let data = try read(offset: offset, count: count)
                hash.update(data: data)
                offset += Int64(count)
                remaining -= Int64(count)
            }
            let value = hash.finalize().map {
                String(format: "%02x", $0)
            }.joined()
            guard value == content.digest.encoded else {
                throw ImageSBOMError.invalidDocument
            }
        default:
            throw ImageSBOMError.invalidDocument
        }
    }

    func packageDatabases(
        in layer: OCIContentDescriptor,
        maximumOutputBytes: Int
    ) throws -> (alpine: Data?, debian: Data?) {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-sbom-layer-\(UUID().uuidString).tar"
            ).path
        let output = Darwin.open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard output >= 0 else {
            throw ImageSBOMError.invalidDocument
        }
        defer {
            Darwin.close(output)
            try? FileManager.default.removeItem(atPath: temporary)
        }
        let path = "blobs/\(layer.digest.algorithm)/" +
            layer.digest.encoded
        guard let entry = entries[path],
              entry.size == layer.size else {
            throw ImageSBOMError.invalidDocument
        }
        var offset = entry.offset
        var remaining = entry.size
        while remaining > 0 {
            let count = Int(min(remaining, 64 * 1_024))
            let data = try read(offset: offset, count: count)
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let result = Darwin.write(
                        output,
                        bytes.baseAddress!.advanced(by: written),
                        bytes.count - written
                    )
                    guard result > 0 else {
                        throw ImageSBOMError.invalidDocument
                    }
                    written += result
                }
            }
            offset += Int64(count)
            remaining -= Int64(count)
        }
        guard fsync(output) == 0 else {
            throw ImageSBOMError.invalidDocument
        }
        let runner = SecureSubprocessRunner()
        return (
            try extract(
                runner: runner,
                archive: temporary,
                path: "lib/apk/db/installed",
                maximumBytes: maximumOutputBytes
            ),
            try extract(
                runner: runner,
                archive: temporary,
                path: "var/lib/dpkg/status",
                maximumBytes: maximumOutputBytes
            )
        )
    }

    private func extract(
        runner: SecureSubprocessRunner,
        archive: String,
        path: String,
        maximumBytes: Int
    ) throws -> Data? {
        let request = SecureSubprocessRequest(
            executablePath: "/usr/bin/bsdtar",
            arguments: ["-xOf", archive, path],
            environment: SecureSubprocessEnvironment.minimal,
            timeoutMilliseconds: 30_000,
            maximumStandardOutputBytes: maximumBytes,
            maximumStandardErrorBytes: 4_096
        )
        do {
            let result = try runner.run(
                request,
                cancellation: cancellation
            )
            guard result.exitStatus == 0 else { return nil }
            return result.standardOutput
        } catch let error as SecureSubprocessError {
            if case .cancelled = error {
                throw ImageSBOMError.cancelled
            }
            throw ImageSBOMError.invalidDocument
        } catch {
            throw ImageSBOMError.invalidDocument
        }
    }

    private func index() throws {
        var offset: Int64 = 0
        var pendingPath: String?
        var zeroBlocks = 0
        while offset + 512 <= fileSize {
            try checkCancellation()
            let header = try read(offset: offset, count: 512)
            if header.allSatisfy({ $0 == 0 }) {
                zeroBlocks += 1
                offset += 512
                if zeroBlocks == 2 { return }
                continue
            }
            zeroBlocks = 0
            guard validChecksum(header) else {
                throw ImageSBOMError.invalidDocument
            }
            let size = try octal(header[124..<136])
            let type = header[156]
            let rawName = string(header[0..<100])
            let prefix = string(header[345..<500])
            var path = prefix.isEmpty ? rawName : "\(prefix)/\(rawName)"
            if let override = pendingPath {
                path = override
                pendingPath = nil
            }
            let dataOffset = offset + 512
            let padded = ((size + 511) / 512) * 512
            guard size >= 0,
                  dataOffset + padded <= fileSize else {
                throw ImageSBOMError.invalidDocument
            }
            switch type {
            case 0, 48:
                path = try normalized(path)
                guard entries[path] == nil else {
                    throw ImageSBOMError.invalidDocument
                }
                entries[path] = Entry(
                    offset: dataOffset,
                    size: size
                )
                guard entries.count <=
                        OCIImageArchiveSBOMGenerator
                            .maximumArchiveEntries else {
                    throw ImageSBOMError.limitExceeded
                }
            case 53:
                while path.hasSuffix("/") {
                    path.removeLast()
                }
                _ = try normalized(path)
            case 76:
                guard size <= 4_096 else {
                    throw ImageSBOMError.limitExceeded
                }
                let data = try read(
                    offset: dataOffset,
                    count: Int(size)
                )
                guard let value = String(
                    data: data.prefix { $0 != 0 },
                    encoding: .utf8
                ) else {
                    throw ImageSBOMError.invalidDocument
                }
                pendingPath = try normalized(value)
            case 120:
                guard size <= 64 * 1_024 else {
                    throw ImageSBOMError.limitExceeded
                }
                let data = try read(
                    offset: dataOffset,
                    count: Int(size)
                )
                pendingPath = try paxPath(data) ?? pendingPath
            case 103:
                guard size <= 64 * 1_024 else {
                    throw ImageSBOMError.limitExceeded
                }
            default:
                throw ImageSBOMError.invalidDocument
            }
            offset = dataOffset + padded
        }
        throw ImageSBOMError.invalidDocument
    }

    private func paxPath(_ data: Data) throws -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImageSBOMError.invalidDocument
        }
        var result: String?
        for line in text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " "),
                  Int(line[..<space]) != nil,
                  let separator = line.firstIndex(of: "=") else {
                throw ImageSBOMError.invalidDocument
            }
            let key = line[line.index(after: space)..<separator]
            let value = String(line[line.index(after: separator)...])
            if key == "path" {
                result = try normalized(value)
            } else if ["size", "linkpath"].contains(String(key)) {
                throw ImageSBOMError.invalidDocument
            }
        }
        return result
    }

    private func normalized(_ raw: String) throws -> String {
        var value = raw
        while value.hasPrefix("./") {
            value.removeFirst(2)
        }
        let parts = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              !value.hasPrefix("/"),
              !value.contains("\0"),
              parts.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw ImageSBOMError.invalidDocument
        }
        return value
    }

    private func validChecksum(_ header: Data) -> Bool {
        guard let expected = try? octal(header[148..<156]) else {
            return false
        }
        var sum: Int64 = 0
        for index in header.indices {
            sum += Int64(
                (148..<156).contains(index) ? 32 : header[index]
            )
        }
        return sum == expected
    }

    private func octal(
        _ bytes: Data.SubSequence
    ) throws -> Int64 {
        let raw = String(
            data: Data(bytes),
            encoding: .ascii
        )?.trimmingCharacters(
            in: CharacterSet(charactersIn: "\0 ")
        ) ?? ""
        guard raw.isEmpty ||
                raw.allSatisfy({ ("0"..."7").contains($0) }),
              let value = Int64(raw.isEmpty ? "0" : raw, radix: 8)
        else {
            throw ImageSBOMError.invalidDocument
        }
        return value
    }

    private func string(
        _ bytes: Data.SubSequence
    ) -> String {
        String(
            data: Data(bytes.prefix { $0 != 0 }),
            encoding: .utf8
        ) ?? ""
    }

    private func read(
        offset: Int64,
        count: Int
    ) throws -> Data {
        guard offset >= 0,
              count >= 0,
              offset + Int64(count) <= fileSize else {
            throw ImageSBOMError.invalidDocument
        }
        var data = Data(count: count)
        var completed = 0
        while completed < count {
            try checkCancellation()
            let result = data.withUnsafeMutableBytes { buffer in
                pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: completed),
                    count - completed,
                    offset + Int64(completed)
                )
            }
            guard result > 0 else {
                throw ImageSBOMError.invalidDocument
            }
            completed += result
        }
        return data
    }

    private func checkCancellation() throws {
        if cancellation.isCancelled {
            throw ImageSBOMError.cancelled
        }
    }
}

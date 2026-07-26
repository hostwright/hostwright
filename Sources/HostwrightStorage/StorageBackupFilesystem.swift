import Compression
import CryptoKit
import Foundation
import HostwrightSecrets

enum StorageBackupFilesystem {
    static let maximumObjectBytes: Int64 = 64 * 1_024 * 1_024

    static func compress(_ data: Data) throws -> Data {
        try transcode(data, operation: COMPRESSION_STREAM_ENCODE)
    }

    static func decompress(_ data: Data) throws -> Data {
        try transcode(data, operation: COMPRESSION_STREAM_DECODE)
    }

    static func writeAtomic<T: Encodable>(_ value: T, to url: URL) throws {
        try StorageSnapshotFilesystem.writeAtomicJSON(value, to: url)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try StorageSnapshotFilesystem.readJSON(type, from: url)
    }

    static func ensureRoot(_ url: URL) throws {
        try StorageSnapshotFilesystem.ensurePrivateRoot(url)
        try makeDirectoryIfMissing(url.appendingPathComponent("sets", isDirectory: true))
        try makeDirectoryIfMissing(url.appendingPathComponent("chunks", isDirectory: true))
        try makeDirectoryIfMissing(url.appendingPathComponent(".operations", isDirectory: true))
        try makeDirectoryIfMissing(url.appendingPathComponent(".staging", isDirectory: true))
    }

    static func hashData(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func dataFromFile(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if Int64(data.count) > maximumObjectBytes {
            throw StorageBackupError.incompleteBackup
        }
        return data
    }

    static func encrypt(
        plaintext: Data,
        key: SymmetricKey
    ) throws -> (ciphertext: Data, nonceBase64: String, tagBase64: String) {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        guard let combined = sealed.ciphertext as Data? else {
            throw StorageBackupError.ioFailure
        }
        return (
            ciphertext: combined,
            nonceBase64: Data(sealed.nonce).base64EncodedString(),
            tagBase64: sealed.tag.base64EncodedString()
        )
    }

    static func decrypt(
        ciphertext: Data,
        nonceBase64: String,
        tagBase64: String,
        key: SymmetricKey
    ) throws -> Data {
        guard let nonceData = Data(base64Encoded: nonceBase64),
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let tag = Data(base64Encoded: tagBase64) else {
            throw StorageBackupError.incompleteBackup
        }
        let sealed = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        do {
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw StorageBackupError.wrongKey
        }
    }

    static func enumerateTree(
        root: URL
    ) throws -> [(relativePath: String, kind: String, mode: UInt16, url: URL)] {
        try StorageSnapshotFilesystem.requireDirectory(root)
        var results: [(String, String, UInt16, URL)] = []
        try walk(root: root, current: root, results: &results)
        return results.sorted { $0.0 < $1.0 }
    }

    static func verifyChunk(
        chunkRoot: URL,
        record: StorageBackupChunkRecord,
        key: SymmetricKey
    ) throws {
        let decoderRoot = chunkRoot.appendingPathComponent("blobs", isDirectory: true)
        try verifyKey(record.keyVerifier, blobRoot: decoderRoot, key: key)
        var hasher = SHA256()
        hasher.update(
            data: snapshotTreeDigestLine(
                kind: "dir",
                relativePath: "",
                mode: 0o700,
                contentSHA256: ""
            )
        )
        var totalBytes: Int64 = 0
        for entry in record.entries {
            hasher.update(
                data: snapshotTreeDigestLine(
                    kind: entry.kind,
                    relativePath: entry.relativePath,
                    mode: entry.mode,
                    contentSHA256:
                        entry.contentSHA256
                )
            )
            if entry.kind == "file" {
                guard let blob = entry.blob else {
                    throw StorageBackupError.incompleteBackup
                }
                let blobURL = decoderRoot.appendingPathComponent(blob.blobID, isDirectory: false)
                let encrypted = try dataFromFile(blobURL)
                guard hashData(encrypted) == blob.encryptedSHA256 else {
                    throw StorageBackupError.integrityMismatch
                }
                let compressed = try decrypt(
                    ciphertext: encrypted,
                    nonceBase64: blob.nonceBase64,
                    tagBase64: blob.tagBase64,
                    key: key
                )
                guard hashData(compressed) == blob.compressedSHA256 else {
                    throw StorageBackupError.integrityMismatch
                }
                let plaintext = try decompress(compressed)
                guard hashData(plaintext) == entry.contentSHA256 else {
                    throw StorageBackupError.integrityMismatch
                }
                totalBytes += Int64(plaintext.count)
            }
        }
        let volumeDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard volumeDigest == record.volumeDigest,
              totalBytes == record.totalPlaintextBytes else {
            throw StorageBackupError.integrityMismatch
        }
    }

    static func verifyEncryptedArtifact(
        chunkRoot: URL,
        record: StorageBackupChunkRecord
    ) throws {
        guard record.entries.count <=
                StorageSemanticLimits.maximumResources,
              Set(record.entries.map(\.relativePath)).count ==
                record.entries.count,
              record.totalPlaintextBytes >= 0,
              record.totalPlaintextBytes <=
                maximumObjectBytes *
                Int64(
                    max(
                        record.entries.count,
                        1
                    )
                ) else {
            throw StorageBackupError.integrityMismatch
        }
        let blobRoot = chunkRoot.appendingPathComponent(
            "blobs",
            isDirectory: true
        )
        try verifyEncryptedBlob(
            record.keyVerifier,
            blobRoot: blobRoot
        )
        var hasher = SHA256()
        hasher.update(
            data: snapshotTreeDigestLine(
                kind: "dir",
                relativePath: "",
                mode: 0o700,
                contentSHA256: ""
            )
        )
        var totalBytes: Int64 = 0
        for entry in record.entries {
            guard validRelativePath(entry.relativePath),
                  entry.mode <= 0o7777,
                  entry.kind == "dir" ||
                    entry.kind == "file",
                  entry.sizeBytes >= 0,
                  entry.sizeBytes <= maximumObjectBytes else {
                throw StorageBackupError.integrityMismatch
            }
            hasher.update(
                data: snapshotTreeDigestLine(
                    kind: entry.kind,
                    relativePath: entry.relativePath,
                    mode: entry.mode,
                    contentSHA256:
                        entry.contentSHA256
                )
            )
            if entry.kind == "dir" {
                guard entry.blob == nil,
                      entry.contentSHA256.isEmpty,
                      entry.sizeBytes == 0 else {
                    throw StorageBackupError.integrityMismatch
                }
                continue
            }
            guard let blob = entry.blob,
                  blob.plaintextSHA256 ==
                    entry.contentSHA256,
                  blob.plaintextBytes == entry.sizeBytes else {
                throw StorageBackupError.integrityMismatch
            }
            try verifyEncryptedBlob(
                blob,
                blobRoot: blobRoot
            )
            let updated = totalBytes.addingReportingOverflow(
                entry.sizeBytes
            )
            guard !updated.overflow else {
                throw StorageBackupError.integrityMismatch
            }
            totalBytes = updated.partialValue
        }
        let volumeDigest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        guard volumeDigest == record.volumeDigest,
              totalBytes == record.totalPlaintextBytes else {
            throw StorageBackupError.integrityMismatch
        }
    }

    static func materializeChunk(
        chunkRoot: URL,
        record: StorageBackupChunkRecord,
        key: SymmetricKey,
        stageRoot: URL,
        hooks: StorageBackupHooks
    ) throws {
        try StorageSnapshotFilesystem.ensureAbsentPath(stageRoot)
        try FileManager.default.createDirectory(
            at: stageRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let blobRoot = chunkRoot.appendingPathComponent("blobs", isDirectory: true)
        try verifyKey(record.keyVerifier, blobRoot: blobRoot, key: key)
        for entry in record.entries {
            if hooks.isCancelled() {
                throw StorageBackupError.cancelled
            }
            let target = stageRoot.appendingPathComponent(entry.relativePath, isDirectory: entry.kind == "dir")
            if entry.kind == "dir" {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: entry.mode)]
                )
                guard chmod(target.path, mode_t(entry.mode)) == 0 else {
                    throw StorageBackupError.ioFailure
                }
                continue
            }
            guard let blob = entry.blob else {
                throw StorageBackupError.incompleteBackup
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encrypted = try dataFromFile(
                blobRoot.appendingPathComponent(blob.blobID, isDirectory: false)
            )
            let compressed = try decrypt(
                ciphertext: encrypted,
                nonceBase64: blob.nonceBase64,
                tagBase64: blob.tagBase64,
                key: key
            )
            let plaintext = try decompress(compressed)
            guard hashData(plaintext) == entry.contentSHA256 else {
                throw StorageBackupError.integrityMismatch
            }
            try plaintext.write(to: target, options: .atomic)
            guard chmod(target.path, mode_t(entry.mode)) == 0 else {
                throw StorageBackupError.ioFailure
            }
        }
        let digest = try StorageSnapshotFilesystem.hashTree(
            at: stageRoot,
            hooks: StorageSnapshotHooks(isCancelled: hooks.isCancelled)
        )
        guard digest.sha256 == record.volumeDigest else {
            throw StorageBackupError.integrityMismatch
        }
    }

    private static func verifyKey(
        _ verifier: StorageBackupEncryptedBlob,
        blobRoot: URL,
        key: SymmetricKey
    ) throws {
        let blobURL = blobRoot.appendingPathComponent(verifier.blobID, isDirectory: false)
        let encrypted = try dataFromFile(blobURL)
        guard hashData(encrypted) == verifier.encryptedSHA256 else {
            throw StorageBackupError.integrityMismatch
        }
        let compressed = try decrypt(
            ciphertext: encrypted,
            nonceBase64: verifier.nonceBase64,
            tagBase64: verifier.tagBase64,
            key: key
        )
        guard hashData(compressed) == verifier.compressedSHA256 else {
            throw StorageBackupError.integrityMismatch
        }
        let plaintext = try decompress(compressed)
        guard hashData(plaintext) == verifier.plaintextSHA256 else {
            throw StorageBackupError.integrityMismatch
        }
    }

    private static func verifyEncryptedBlob(
        _ blob: StorageBackupEncryptedBlob,
        blobRoot: URL
    ) throws {
        guard validSHA256(blob.plaintextSHA256),
              validSHA256(blob.compressedSHA256),
              validSHA256(blob.encryptedSHA256),
              blob.plaintextBytes >= 0,
              blob.plaintextBytes <= maximumObjectBytes,
              blob.compressedBytes >= 0,
              blob.compressedBytes <= maximumObjectBytes,
              blob.encryptedBytes >= 0,
              blob.encryptedBytes <= maximumObjectBytes,
              Data(base64Encoded: blob.nonceBase64) != nil,
              Data(base64Encoded: blob.tagBase64) != nil,
              !blob.blobID.isEmpty,
              blob.blobID.utf8.count <= 255,
              !blob.blobID.contains("/"),
              blob.blobID != ".",
              blob.blobID != ".." else {
            throw StorageBackupError.integrityMismatch
        }
        let encrypted = try dataFromFile(
            blobRoot.appendingPathComponent(
                blob.blobID,
                isDirectory: false
            )
        )
        guard Int64(encrypted.count) ==
                blob.encryptedBytes,
              hashData(encrypted) ==
                blob.encryptedSHA256 else {
            throw StorageBackupError.integrityMismatch
        }
    }

    private static func validRelativePath(
        _ value: String
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <=
                StorageSemanticLimits.maximumPathBytes &&
            !value.hasPrefix("/") &&
            value.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 &&
            value.allSatisfy {
                ("0"..."9").contains($0) ||
                    ("a"..."f").contains($0)
            }
    }

    static func snapshotTreeDigestLine(
        kind: String,
        relativePath: String,
        mode: UInt16,
        contentSHA256: String
    ) -> Data {
        let permissions = String(
            format: "%04o",
            UInt32(mode)
        )
        return Data(
            "\(kind)\t\(relativePath)\t\(permissions)\t\(contentSHA256)\n"
                .utf8
        )
    }

    private static func transcode(
        _ data: Data,
        operation: compression_stream_operation
    ) throws -> Data {
        if data.isEmpty {
            return Data()
        }
        return try data.withUnsafeBytes { sourceBuffer in
            guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw StorageBackupError.ioFailure
            }
            var destinationCapacity = max(data.count * 4, 64 * 1_024)
            while destinationCapacity <= Int(StorageBackupFilesystem.maximumObjectBytes) {
                let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
                defer { destination.deallocate() }
                let written: Int = {
                    switch operation {
                    case COMPRESSION_STREAM_ENCODE:
                        return compression_encode_buffer(
                            destination,
                            destinationCapacity,
                            sourceBase,
                            data.count,
                            nil,
                            COMPRESSION_LZFSE
                        )
                    case COMPRESSION_STREAM_DECODE:
                        return compression_decode_buffer(
                            destination,
                            destinationCapacity,
                            sourceBase,
                            data.count,
                            nil,
                            COMPRESSION_LZFSE
                        )
                    default:
                        return 0
                    }
                }()
                if written > 0 {
                    return Data(bytes: destination, count: written)
                }
                destinationCapacity *= 2
            }
            throw StorageBackupError.ioFailure
        }
    }

    private static func makeDirectoryIfMissing(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try StorageSnapshotFilesystem.makeDirectory(url)
        }
        try StorageSnapshotFilesystem.requireDirectory(url)
        try StorageSnapshotFilesystem.setMode(url, mode: 0o700)
    }

    private static func walk(
        root: URL,
        current: URL,
        results: inout [(String, String, UInt16, URL)]
    ) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: current,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for item in contents {
            var metadata = stat()
            guard lstat(item.path, &metadata) == 0 else {
                throw StorageBackupError.ioFailure
            }
            let relative = item.path.replacingOccurrences(of: root.path + "/", with: "")
            let mode = UInt16(metadata.st_mode & 0o7777)
            let type = metadata.st_mode & S_IFMT
            if type == S_IFDIR {
                results.append((relative, "dir", mode, item))
                try walk(root: root, current: item, results: &results)
            } else if type == S_IFREG, metadata.st_nlink == 1 {
                results.append((relative, "file", mode, item))
            } else {
                throw StorageBackupError.integrityMismatch
            }
        }
    }
}

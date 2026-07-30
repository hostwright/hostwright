import CryptoKit
import Darwin
import Foundation
import Security

public struct SecurityDetachedCMSVerifier: DetachedCMSVerifier {
    private let trustedCertificateDER: Set<Data>

    public init(trustedCertificateDER: [Data]) {
        self.trustedCertificateDER = Set(trustedCertificateDER)
    }

    public func verifyDetachedCMS(
        signature: Data,
        content: Data,
        trustedSigner: String
    ) throws {
        guard !trustedCertificateDER.isEmpty,
              !signature.isEmpty,
              trustedSigner.range(
            of: "^sha256:[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil else {
            throw NetworkProviderError.untrustedSignature
        }

        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess,
              let decoder,
              CMSDecoderSetDetachedContent(decoder, content as CFData) == errSecSuccess
        else {
            throw NetworkProviderError.untrustedSignature
        }
        let updateStatus = signature.withUnsafeBytes { bytes in
            CMSDecoderUpdateMessage(
                decoder,
                bytes.baseAddress!,
                bytes.count
            )
        }
        guard updateStatus == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess
        else {
            throw NetworkProviderError.untrustedSignature
        }

        var signerCount = 0
        guard CMSDecoderGetNumSigners(decoder, &signerCount) == errSecSuccess,
              signerCount == 1
        else {
            throw NetworkProviderError.untrustedSignature
        }

        let policy = SecPolicyCreateBasicX509()
        var signerStatus = CMSSignerStatus.unsigned
        var trust: SecTrust?
        var verificationResult = errSecSuccess
        guard CMSDecoderCopySignerStatus(
            decoder,
            0,
            policy,
            false,
            &signerStatus,
            &trust,
            &verificationResult
        ) == errSecSuccess,
              signerStatus == .valid,
              let trust
        else {
            throw NetworkProviderError.untrustedSignature
        }

        var certificate: SecCertificate?
        guard CMSDecoderCopySignerCert(
            decoder,
            0,
            &certificate
        ) == errSecSuccess,
              let certificate
        else {
            throw NetworkProviderError.untrustedSignature
        }
        let certificateData = SecCertificateCopyData(certificate) as Data
        let fingerprint = "sha256:" + SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard fingerprint == trustedSigner else {
            throw NetworkProviderError.untrustedSignature
        }

        guard trustedCertificateDER.contains(certificateData),
              SecTrustSetAnchorCertificates(
                  trust,
                  [certificate] as CFArray
              ) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else {
            throw NetworkProviderError.untrustedSignature
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            throw NetworkProviderError.untrustedSignature
        }
    }
}

public actor FileBackedNetworkProviderRevocationStore:
    NetworkProviderRevocationStore
{
    public static let maximumStateBytes = 1 * 1_024 * 1_024

    private let directoryURL: URL
    private let stateURL: URL
    private var records: [RevocationRecord]

    public init(directoryURL: URL) throws {
        guard directoryURL.isFileURL else {
            throw NetworkProviderError.executionFailed
        }
        let directoryURL = directoryURL.standardizedFileURL
        try Self.prepareDirectory(directoryURL)
        let stateURL = directoryURL.appendingPathComponent(
            "network-provider-revocations.json",
            isDirectory: false
        )
        self.directoryURL = directoryURL
        self.stateURL = stateURL
        records = try Self.loadState(from: stateURL)
    }

    public func isRevoked(
        identifier: String,
        moduleSHA256: String
    ) async throws -> Bool {
        records.contains {
            $0.identifier == identifier && $0.moduleSHA256 == moduleSHA256
        }
    }

    public func revoke(
        identifier: String,
        moduleSHA256: String,
        at: Date
    ) async throws {
        guard Self.isValidIdentifier(identifier),
              moduleSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil
        else {
            throw NetworkProviderError.invalidDeclaration
        }
        if records.contains(where: {
            $0.identifier == identifier && $0.moduleSHA256 == moduleSHA256
        }) {
            return
        }
        var updated = records
        updated.append(
            RevocationRecord(
                identifier: identifier,
                moduleSHA256: moduleSHA256,
                revokedAt: at
            )
        )
        updated.sort {
            if $0.identifier != $1.identifier {
                return $0.identifier < $1.identifier
            }
            return $0.moduleSHA256 < $1.moduleSHA256
        }
        try Self.persist(
            RevocationState(version: 1, records: updated),
            stateURL: stateURL,
            directoryURL: directoryURL
        )
        records = updated
    }

    private static func prepareDirectory(_ directoryURL: URL) throws {
        var metadata = stat()
        let status = directoryURL.path.withCString {
            lstat($0, &metadata)
        }
        if status == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_mode & S_IFMT != S_IFLNK,
                  metadata.st_uid == geteuid()
            else {
                throw NetworkProviderError.executionFailed
            }
        } else {
            guard errno == ENOENT else {
                throw NetworkProviderError.executionFailed
            }
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard chmod(directoryURL.path, 0o700) == 0 else {
            throw NetworkProviderError.executionFailed
        }
    }

    private static func loadState(from stateURL: URL) throws -> [RevocationRecord] {
        let descriptor = open(
            stateURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return []
            }
            throw NetworkProviderError.executionFailed
        }
        defer {
            close(descriptor)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NetworkProviderError.executionFailed
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0,
              metadata.st_size >= 0,
              metadata.st_size <= maximumStateBytes
        else {
            throw NetworkProviderError.executionFailed
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw NetworkProviderError.executionFailed
            }
            if count == 0 {
                break
            }
            guard count <= maximumStateBytes - data.count else {
                throw NetworkProviderError.executionFailed
            }
            data.append(contentsOf: buffer[0..<count])
        }
        guard data.count <= maximumStateBytes,
              let state = try? JSONDecoder().decode(
                  RevocationState.self,
                  from: data
              ),
              state.version == 1,
              state.records.allSatisfy({
                  isValidIdentifier($0.identifier)
                      && $0.moduleSHA256.range(
                          of: "^[a-f0-9]{64}$",
                          options: .regularExpression
                      ) != nil
              }),
              Set(state.records.map(\.key)).count == state.records.count,
              (try? encode(state)) == data
        else {
            throw NetworkProviderError.executionFailed
        }
        return state.records
    }

    private static func persist(
        _ state: RevocationState,
        stateURL: URL,
        directoryURL: URL
    ) throws {
        let data = try encode(state)
        guard data.count <= maximumStateBytes else {
            throw NetworkProviderError.outputLimitExceeded
        }
        let temporaryURL = directoryURL.appendingPathComponent(
            ".revocations-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw NetworkProviderError.executionFailed
        }
        var shouldRemoveTemporaryFile = true
        defer {
            close(descriptor)
            if shouldRemoveTemporaryFile {
                unlink(temporaryURL.path)
            }
        }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw NetworkProviderError.executionFailed
                }
                written += count
            }
        }
        guard fsync(descriptor) == 0,
              rename(temporaryURL.path, stateURL.path) == 0
        else {
            throw NetworkProviderError.executionFailed
        }
        shouldRemoveTemporaryFile = false
        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw NetworkProviderError.executionFailed
        }
        defer {
            close(directoryDescriptor)
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw NetworkProviderError.executionFailed
        }
    }

    private static func encode(_ state: RevocationState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(state)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        value.range(
            of: "^[a-z0-9](?:[a-z0-9.-]{0,126}[a-z0-9])?$",
            options: .regularExpression
        ) != nil && !value.contains("..")
    }
}

private struct RevocationState: Codable {
    let version: Int
    let records: [RevocationRecord]
}

private struct RevocationRecord: Codable {
    let identifier: String
    let moduleSHA256: String
    let revokedAt: Date

    var key: String {
        "\(identifier):\(moduleSHA256)"
    }
}

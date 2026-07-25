import CryptoKit
import Darwin
import Foundation
import HostwrightCore

public enum ImageTrustAuthorityKind: String, Codable, Equatable, Sendable {
    case keyed
    case keyless
}

public struct ImageTrustAuthority: Equatable, Sendable {
    public let id: String
    public let kind: ImageTrustAuthorityKind
    public let publicKeyPath: String?
    public let issuer: String?
    public let identity: String?
    public let notBefore: Date?
    public let notAfter: Date?
    public let revokedAt: Date?

    public init(
        id: String,
        kind: ImageTrustAuthorityKind,
        publicKeyPath: String? = nil,
        issuer: String? = nil,
        identity: String? = nil,
        notBefore: Date? = nil,
        notAfter: Date? = nil,
        revokedAt: Date? = nil
    ) throws {
        guard id.range(
            of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$"#,
            options: .regularExpression
        ) != nil else {
            throw ImageTrustVerifierError.invalidPolicy
        }
        switch kind {
        case .keyed:
            guard let publicKeyPath,
                  Self.validAbsolutePath(publicKeyPath),
                  issuer == nil,
                  identity == nil else {
                throw ImageTrustVerifierError.invalidPolicy
            }
        case .keyless:
            guard publicKeyPath == nil,
                  let issuer,
                  Self.validHTTPSURL(issuer),
                  let identity,
                  !identity.isEmpty,
                  identity.utf8.count <= 2_048,
                  !identity.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw ImageTrustVerifierError.invalidPolicy
            }
        }
        if let notBefore, let notAfter, notAfter <= notBefore {
            throw ImageTrustVerifierError.invalidPolicy
        }
        if let notBefore, let revokedAt, revokedAt < notBefore {
            throw ImageTrustVerifierError.invalidPolicy
        }
        self.id = id
        self.kind = kind
        self.publicKeyPath = publicKeyPath
        self.issuer = issuer
        self.identity = identity
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.revokedAt = revokedAt
    }

    private static func validAbsolutePath(_ value: String) -> Bool {
        value.utf8.count <= 4_096 &&
            value.hasPrefix("/") &&
            URL(fileURLWithPath: value).standardizedFileURL.path == value &&
            !value.contains("\0")
    }

    private static func validHTTPSURL(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048,
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return false
        }
        return true
    }
}

public struct ImageTrustVerificationPolicy: Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let threshold: Int
    public let trustedRootPath: String?
    public let authorities: [ImageTrustAuthority]

    public init(
        version: Int = Self.currentVersion,
        threshold: Int,
        trustedRootPath: String?,
        authorities: [ImageTrustAuthority]
    ) throws {
        guard version == Self.currentVersion,
              (1...8).contains(threshold),
              (1...8).contains(authorities.count),
              threshold <= authorities.count,
              Set(authorities.map(\.id)).count == authorities.count,
              trustedRootPath.map({
                  $0.utf8.count <= 4_096 &&
                      $0.hasPrefix("/") &&
                      URL(fileURLWithPath: $0).standardizedFileURL.path == $0 &&
                      !$0.contains("\0")
              }) ?? true,
              !authorities.contains(where: {
                  $0.kind == .keyless && trustedRootPath == nil
              }) else {
            throw ImageTrustVerifierError.invalidPolicy
        }
        self.version = version
        self.threshold = threshold
        self.trustedRootPath = trustedRootPath
        self.authorities = authorities.sorted { $0.id < $1.id }
    }
}

public struct ImageTrustPolicyMaterial: Equatable, Sendable {
    public let policySHA256: String
    public let trustedRootSHA256: String?
    public let authorityMaterialSHA256: [String: String]

    public static func resolve(
        _ policy: ImageTrustVerificationPolicy
    ) throws -> ImageTrustPolicyMaterial {
        let rootData = try policy.trustedRootPath.map {
            try imageTrustSecureFileData(
                path: $0,
                maximumBytes: 8 * 1_024 * 1_024
            )
        }
        var authorityDigests: [String: String] = [:]
        for authority in policy.authorities where authority.kind == .keyed {
            authorityDigests[authority.id] = imageTrustHexDigest(
                try imageTrustSecureFileData(
                    path: authority.publicKeyPath!,
                    maximumBytes: 1 * 1_024 * 1_024
                )
            )
        }
        let rootDigest = rootData.map(imageTrustHexDigest)
        let authorities = policy.authorities.map { authority -> [String: Any] in
            var value: [String: Any] = [
                "id": authority.id,
                "kind": authority.kind.rawValue
            ]
            if let path = authority.publicKeyPath {
                value["publicKeyPath"] = path
                value["publicKeySHA256"] = authorityDigests[authority.id]!
            }
            if let issuer = authority.issuer {
                value["issuer"] = issuer
            }
            if let identity = authority.identity {
                value["identity"] = identity
            }
            if let notBefore = authority.notBefore {
                value["notBeforeMilliseconds"] =
                    Int64((notBefore.timeIntervalSince1970 * 1_000).rounded())
            }
            if let notAfter = authority.notAfter {
                value["notAfterMilliseconds"] =
                    Int64((notAfter.timeIntervalSince1970 * 1_000).rounded())
            }
            if let revokedAt = authority.revokedAt {
                value["revokedAtMilliseconds"] =
                    Int64((revokedAt.timeIntervalSince1970 * 1_000).rounded())
            }
            return value
        }
        var canonical: [String: Any] = [
            "version": policy.version,
            "threshold": policy.threshold,
            "authorities": authorities
        ]
        if let path = policy.trustedRootPath,
           let rootDigest {
            canonical["trustedRootPath"] = path
            canonical["trustedRootSHA256"] = rootDigest
        }
        guard JSONSerialization.isValidJSONObject(canonical),
              let data = try? JSONSerialization.data(
                  withJSONObject: canonical,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            throw ImageTrustVerifierError.invalidPolicy
        }
        return ImageTrustPolicyMaterial(
            policySHA256: imageTrustHexDigest(data),
            trustedRootSHA256: rootDigest,
            authorityMaterialSHA256: authorityDigests
        )
    }
}

public struct SigstoreBundleEvidence: Equatable, Sendable {
    public static let mediaType =
        "application/vnd.dev.sigstore.bundle.v0.3+json"
    public static let maximumBytes = 8 * 1_024 * 1_024

    public let digest: String
    public let payload: Data
    public let signedContentSHA256: String

    public init(digest: String, payload: Data) throws {
        let parsedDigest: OCIContentDigest
        do {
            parsedDigest = try OCIContentDigest(digest)
        } catch {
            throw ImageTrustVerifierError.invalidBundle
        }
        guard parsedDigest.algorithm == "sha256",
              payload.count <= Self.maximumBytes,
              try parsedDigest.matches(payload) else {
            throw ImageTrustVerifierError.invalidBundle
        }
        do {
            let object = try RegistryStrictJSONObject.decode(
                payload,
                maximumBytes: Self.maximumBytes,
                allowedKeys: [
                    "mediaType", "messageSignature", "verificationMaterial"
                ],
                requiredKeys: [
                    "mediaType", "messageSignature", "verificationMaterial"
                ]
            )
            guard object["mediaType"] as? String == Self.mediaType,
                  let message = object["messageSignature"]
                    as? [String: Any],
                  Set(message.keys) == ["messageDigest", "signature"],
                  message["signature"] is String,
                  let messageDigest = message["messageDigest"]
                    as? [String: Any],
                  Set(messageDigest.keys) == ["algorithm", "digest"],
                  messageDigest["algorithm"] as? String == "SHA2_256",
                  let encoded = messageDigest["digest"] as? String,
                  let decoded = Data(base64Encoded: encoded),
                  decoded.count == 32 else {
                throw ImageTrustVerifierError.invalidBundle
            }
            signedContentSHA256 = decoded.map {
                String(format: "%02x", $0)
            }.joined()
        } catch let error as ImageTrustVerifierError {
            throw error
        } catch {
            throw ImageTrustVerifierError.invalidBundle
        }
        self.digest = parsedDigest.canonicalValue
        self.payload = payload
    }
}

public enum ImageTrustVerificationOutcome: String, Codable, Equatable, Sendable {
    case passed
    case thresholdNotMet = "threshold-not-met"
}

public struct ImageTrustVerificationResult: Equatable, Sendable {
    public let outcome: ImageTrustVerificationOutcome
    public let subjectDigest: String
    public let matchedAuthorityIDs: [String]
    public let threshold: Int
    public let verifierVersion: String
    public let verifierSHA256: String
    public let trustedRootSHA256: String?
    public let authorityMaterialSHA256: [String: String]
    public let bundleDigests: [String]

    public init(
        outcome: ImageTrustVerificationOutcome,
        subjectDigest: String,
        matchedAuthorityIDs: [String],
        threshold: Int,
        verifierVersion: String,
        verifierSHA256: String,
        trustedRootSHA256: String?,
        authorityMaterialSHA256: [String: String],
        bundleDigests: [String]
    ) {
        self.outcome = outcome
        self.subjectDigest = subjectDigest
        self.matchedAuthorityIDs = matchedAuthorityIDs
        self.threshold = threshold
        self.verifierVersion = verifierVersion
        self.verifierSHA256 = verifierSHA256
        self.trustedRootSHA256 = trustedRootSHA256
        self.authorityMaterialSHA256 = authorityMaterialSHA256
        self.bundleDigests = bundleDigests
    }
}

public enum ImageTrustVerifierError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case invalidPolicy
    case invalidSubject
    case invalidBundle
    case unsupportedVerifier
    case unsafeVerifier
    case verifierChanged
    case verifierUnavailable
    case cancelled
    case cleanupFailed

    public var description: String {
        switch self {
        case .invalidPolicy:
            "Image trust policy is invalid."
        case .invalidSubject:
            "Image trust subject bytes do not match the exact locked digest."
        case .invalidBundle:
            "Sigstore bundle evidence is invalid or unsupported."
        case .unsupportedVerifier:
            "The selected verifier does not implement the required cosign v3 contract."
        case .unsafeVerifier:
            "The selected verifier executable or trust material is unsafe."
        case .verifierChanged:
            "The selected verifier executable changed during verification."
        case .verifierUnavailable:
            "The bounded signature verifier failed."
        case .cancelled:
            "Image trust verification was cancelled."
        case .cleanupFailed:
            "Temporary verification evidence could not be removed exactly."
        }
    }
}

public struct CosignImageTrustVerifier: Sendable {
    public static let minimumSupportedVersion = (major: 3, minor: 0, patch: 6)
    public static let maximumSubjectBytes = 8 * 1_024 * 1_024

    private let executable: SecureExecutableIdentity
    private let runCommand: @Sendable (
        SecureSubprocessRequest,
        SecureSubprocessCancellation
    ) throws -> SecureSubprocessResult

    public init(executablePath: String) throws {
        do {
            executable = try SecureExecutableResolver.verify(
                path: executablePath,
                ownershipPolicy: .rootOrCurrentUser
            )
        } catch {
            throw ImageTrustVerifierError.unsafeVerifier
        }
        runCommand = { request, cancellation in
            try SecureSubprocessRunner().run(
                request,
                cancellation: cancellation
            )
        }
    }

    init(
        executablePath: String,
        runCommand: @escaping @Sendable (
            SecureSubprocessRequest,
            SecureSubprocessCancellation
        ) throws -> SecureSubprocessResult
    ) throws {
        do {
            executable = try SecureExecutableResolver.verify(
                path: executablePath,
                ownershipPolicy: .rootOrCurrentUser
            )
        } catch {
            throw ImageTrustVerifierError.unsafeVerifier
        }
        self.runCommand = runCommand
    }

    public func verify(
        subjectManifest: Data,
        subjectDigest: String,
        bundles: [SigstoreBundleEvidence],
        policy: ImageTrustVerificationPolicy,
        at now: Date = Date(),
        cancellation: SecureSubprocessCancellation =
            SecureSubprocessCancellation()
    ) throws -> ImageTrustVerificationResult {
        let subject: OCIContentDigest
        do {
            subject = try OCIContentDigest(subjectDigest)
        } catch {
            throw ImageTrustVerifierError.invalidSubject
        }
        guard subject.algorithm == "sha256",
              !subjectManifest.isEmpty,
              subjectManifest.count <= Self.maximumSubjectBytes,
              try subject.matches(subjectManifest),
              !bundles.isEmpty,
              bundles.count <= 64 else {
            throw ImageTrustVerifierError.invalidSubject
        }
        let matchingBundles = bundles.filter {
            $0.signedContentSHA256 == subject.encoded
        }
        try verifyExecutableUnchanged()
        let verifierVersion = try probeVersion(cancellation: cancellation)
        let verifierSHA256 = try executableDigest()
        let material = try ImageTrustPolicyMaterial.resolve(policy)
        let trustedRootData = try policy.trustedRootPath.map {
            try imageTrustSecureFileData(
                path: $0,
                maximumBytes: 8 * 1_024 * 1_024
            )
        }
        let trustedRootSHA256 = material.trustedRootSHA256
        var keyedMaterial: [String: Data] = [:]
        for authority in policy.authorities where authority.kind == .keyed {
            keyedMaterial[authority.id] = try imageTrustSecureFileData(
                path: authority.publicKeyPath!,
                maximumBytes: 1 * 1_024 * 1_024
            )
        }
        let authorityMaterialSHA256 = material.authorityMaterialSHA256

        let temporary = try ImageTrustTemporaryDirectory()
        var cleanupError: Error?
        var matched = Set<String>()
        do {
            let bundleFiles = try matchingBundles.enumerated().map {
                index, bundle in
                try temporary.write(
                    bundle.payload,
                    named: "bundle-\(index).sigstore.json"
                )
            }
            let trustedRootFile = try trustedRootData.map {
                try temporary.write($0, named: "trusted-root.json")
            }
            var keyedFiles: [String: String] = [:]
            for (index, authority) in policy.authorities
                .filter({ $0.kind == .keyed })
                .enumerated()
            {
                keyedFiles[authority.id] = try temporary.write(
                    keyedMaterial[authority.id]!,
                    named: "key-\(index).pub"
                )
            }
            for authority in policy.authorities where authority.isActive(at: now) {
                for bundleFile in bundleFiles {
                    guard !cancellation.isCancelled else {
                        throw ImageTrustVerifierError.cancelled
                    }
                    try verifyExecutableUnchanged()
                    let result = try runVerification(
                        subjectManifest: subjectManifest,
                        bundlePath: bundleFile,
                        authority: authority,
                        publicKeyPath: keyedFiles[authority.id],
                        trustedRootPath: trustedRootFile,
                        workingDirectory: temporary.path,
                        cancellation: cancellation
                    )
                    if result {
                        matched.insert(authority.id)
                        break
                    }
                }
            }
        } catch {
            do {
                try temporary.cleanup()
            } catch {
                cleanupError = error
            }
            if cleanupError != nil {
                throw ImageTrustVerifierError.cleanupFailed
            }
            throw error
        }
        do {
            try temporary.cleanup()
        } catch {
            throw ImageTrustVerifierError.cleanupFailed
        }
        let matchedIDs = matched.sorted()
        return ImageTrustVerificationResult(
            outcome: matchedIDs.count >= policy.threshold
                ? .passed
                : .thresholdNotMet,
            subjectDigest: subject.canonicalValue,
            matchedAuthorityIDs: matchedIDs,
            threshold: policy.threshold,
            verifierVersion: verifierVersion,
            verifierSHA256: verifierSHA256,
            trustedRootSHA256: trustedRootSHA256,
            authorityMaterialSHA256: authorityMaterialSHA256,
            bundleDigests: matchingBundles.map(\.digest).sorted()
        )
    }

    private func probeVersion(
        cancellation: SecureSubprocessCancellation
    ) throws -> String {
        let result = try run(
            arguments: ["version", "--json"],
            standardInput: nil,
            workingDirectory: "/",
            timeoutMilliseconds: 5_000,
            maximumOutputBytes: 16 * 1_024,
            cancellation: cancellation
        )
        guard result.exitStatus == 0,
              !result.standardOutputTruncated,
              let object = try? RegistryStrictJSONObject.decode(
                  result.standardOutput,
                  maximumBytes: 16 * 1_024,
                  allowedKeys: [
                      "gitVersion", "gitCommit", "gitTreeState",
                      "buildDate", "goVersion", "compiler", "platform"
                  ],
                  requiredKeys: ["gitVersion", "platform"]
              ),
              let rawVersion = object["gitVersion"] as? String,
              supportedVersion(rawVersion),
              object["platform"] as? String == "darwin/arm64" else {
            throw ImageTrustVerifierError.unsupportedVerifier
        }
        return rawVersion
    }

    private func runVerification(
        subjectManifest: Data,
        bundlePath: String,
        authority: ImageTrustAuthority,
        publicKeyPath: String?,
        trustedRootPath: String?,
        workingDirectory: String,
        cancellation: SecureSubprocessCancellation
    ) throws -> Bool {
        var arguments = [
            "verify-blob",
            "--bundle", bundlePath
        ]
        switch authority.kind {
        case .keyed:
            arguments += ["--key", publicKeyPath!]
        case .keyless:
            arguments += [
                "--trusted-root", trustedRootPath!,
                "--certificate-identity", authority.identity!,
                "--certificate-oidc-issuer", authority.issuer!
            ]
        }
        arguments.append("-")
        let result = try run(
            arguments: arguments,
            standardInput: subjectManifest,
            workingDirectory: workingDirectory,
            timeoutMilliseconds: 30_000,
            maximumOutputBytes: 64 * 1_024,
            cancellation: cancellation
        )
        return result.exitStatus == 0 &&
            !result.standardOutputTruncated &&
            !result.standardErrorTruncated
    }

    private func run(
        arguments: [String],
        standardInput: Data?,
        workingDirectory: String,
        timeoutMilliseconds: Int,
        maximumOutputBytes: Int,
        cancellation: SecureSubprocessCancellation
    ) throws -> SecureSubprocessResult {
        do {
            return try runCommand(
                SecureSubprocessRequest(
                    executablePath: executable.path,
                    arguments: arguments,
                    environment: SecureSubprocessEnvironment.minimal,
                    workingDirectory: workingDirectory,
                    standardInput: standardInput,
                    timeoutMilliseconds: timeoutMilliseconds,
                    maximumStandardOutputBytes: maximumOutputBytes,
                    maximumStandardErrorBytes: maximumOutputBytes,
                    maximumStandardInputBytes: Self.maximumSubjectBytes
                ),
                cancellation
            )
        } catch let error as SecureSubprocessError {
            switch error {
            case .cancelled:
                throw ImageTrustVerifierError.cancelled
            case .executableChanged:
                throw ImageTrustVerifierError.verifierChanged
            default:
                throw ImageTrustVerifierError.verifierUnavailable
            }
        } catch let error as ImageTrustVerifierError {
            throw error
        } catch {
            throw ImageTrustVerifierError.verifierUnavailable
        }
    }

    private func verifyExecutableUnchanged() throws {
        do {
            try SecureExecutableResolver.verifyUnchanged(executable)
        } catch {
            throw ImageTrustVerifierError.verifierChanged
        }
    }

    private func executableDigest() throws -> String {
        try verifyExecutableUnchanged()
        guard executable.sizeBytes <= 256 * 1_024 * 1_024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path)),
              UInt64(data.count) == executable.sizeBytes else {
            throw ImageTrustVerifierError.unsafeVerifier
        }
        try verifyExecutableUnchanged()
        return hexDigest(data)
    }

    private func supportedVersion(_ raw: String) -> Bool {
        guard raw.first == "v" else { return false }
        let parts = raw.dropFirst().split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major == 3 else {
            return false
        }
        return (major, minor, patch) >= Self.minimumSupportedVersion
    }

    private func hexDigest(_ data: Data) -> String {
        imageTrustHexDigest(data)
    }
}

func imageTrustSecureFileData(
    path: String,
    maximumBytes: Int
) throws -> Data {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw ImageTrustVerifierError.unsafeVerifier
    }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_nlink == 1,
          metadata.st_uid == getuid() || metadata.st_uid == 0,
          metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
          metadata.st_size > 0,
          metadata.st_size <= maximumBytes else {
        throw ImageTrustVerifierError.unsafeVerifier
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw ImageTrustVerifierError.unsafeVerifier
        }
        data.append(buffer, count: count)
    }
    guard data.count == metadata.st_size else {
        throw ImageTrustVerifierError.unsafeVerifier
    }
    return data
}

private func imageTrustHexDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension ImageTrustAuthority {
    func isActive(at date: Date) -> Bool {
        if let notBefore, date < notBefore { return false }
        if let notAfter, date > notAfter { return false }
        if let revokedAt, date >= revokedAt { return false }
        return true
    }
}

private final class ImageTrustTemporaryDirectory {
    let path: String
    private var files: [String] = []
    private var cleaned = false

    init() throws {
        var template = Array(
            "\(NSTemporaryDirectory())hostwright-trust.XXXXXX".utf8CString
        )
        guard let created = mkdtemp(&template) else {
            throw ImageTrustVerifierError.verifierUnavailable
        }
        path = String(cString: created)
        guard chmod(path, S_IRWXU) == 0 else {
            _ = rmdir(path)
            throw ImageTrustVerifierError.verifierUnavailable
        }
    }

    func write(_ data: Data, named name: String) throws -> String {
        guard name.range(
            of: "^[a-z0-9.-]{1,128}$",
            options: .regularExpression
        ) != nil else {
            throw ImageTrustVerifierError.invalidBundle
        }
        let file = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false).path
        let descriptor = open(
            file,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ImageTrustVerifierError.verifierUnavailable
        }
        var writeError: Error?
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    writeError = ImageTrustVerifierError.verifierUnavailable
                    break
                }
            }
        }
        if fsync(descriptor) != 0 {
            writeError = ImageTrustVerifierError.verifierUnavailable
        }
        close(descriptor)
        if let writeError {
            _ = unlink(file)
            throw writeError
        }
        files.append(file)
        return file
    }

    func cleanup() throws {
        if cleaned { return }
        for file in files.reversed() {
            guard unlink(file) == 0 || errno == ENOENT else {
                throw ImageTrustVerifierError.cleanupFailed
            }
        }
        guard rmdir(path) == 0 else {
            throw ImageTrustVerifierError.cleanupFailed
        }
        cleaned = true
    }

    deinit {
        if !cleaned {
            for file in files.reversed() {
                _ = unlink(file)
            }
            _ = rmdir(path)
        }
    }
}

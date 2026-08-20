import CryptoKit
import Darwin
import Foundation

public struct QualificationExportVerification: Equatable, Sendable {
  public let data: Data
  public let sha256: String
  public let bytes: UInt64

  public init(data: Data, sha256: String, bytes: UInt64) {
    self.data = data
    self.sha256 = sha256
    self.bytes = bytes
  }
}

public enum QualificationExportVerificationError: Error, Equatable, Sendable {
  case invalidExpectation
  case unsafeParent
  case unsafeOutput
  case outputChanged
  case receiptMismatch
}

public enum QualificationExportVerifier {
  public static let defaultMaximumBytes = 16 * 1_024 * 1_024

  public static func readPrivate(
    path: String,
    owner: uid_t = geteuid(),
    maximumBytes: Int = defaultMaximumBytes
  ) throws -> QualificationExportVerification {
    guard maximumBytes > 0,
      isLexicallyCanonicalAbsolute(path)
    else { throw QualificationExportVerificationError.invalidExpectation }
    return try read(
      path: path,
      owner: owner,
      maximumBytes: maximumBytes
    )
  }

  public static func verify(
    path: String,
    expectedSHA256: String,
    expectedBytes: UInt64,
    owner: uid_t = geteuid(),
    maximumBytes: Int = defaultMaximumBytes
  ) throws -> QualificationExportVerification {
    guard maximumBytes > 0,
      isLexicallyCanonicalAbsolute(path),
      expectedSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      expectedBytes > 0, expectedBytes <= UInt64(maximumBytes)
    else { throw QualificationExportVerificationError.invalidExpectation }
    let result = try read(
      path: path,
      owner: owner,
      maximumBytes: maximumBytes
    )
    guard result.sha256 == expectedSHA256, result.bytes == expectedBytes else {
      throw QualificationExportVerificationError.receiptMismatch
    }
    return result
  }

  private static func read(
    path: String,
    owner: uid_t,
    maximumBytes: Int
  ) throws -> QualificationExportVerification {
    let outputURL = URL(fileURLWithPath: path, isDirectory: false)
    let parentURL = outputURL.deletingLastPathComponent()
    guard let resolvedParent = realpath(parentURL.path, nil) else {
      throw QualificationExportVerificationError.unsafeParent
    }
    defer { free(resolvedParent) }
    guard String(cString: resolvedParent) == parentURL.path else {
      throw QualificationExportVerificationError.unsafeParent
    }

    let parentDescriptor = open(
      parentURL.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard parentDescriptor >= 0 else {
      throw QualificationExportVerificationError.unsafeParent
    }
    defer { close(parentDescriptor) }
    var parentMetadata = stat()
    guard fstat(parentDescriptor, &parentMetadata) == 0,
      (parentMetadata.st_mode & S_IFMT) == S_IFDIR,
      parentMetadata.st_uid == owner,
      parentMetadata.st_mode & mode_t(0o7777) == 0o700
    else { throw QualificationExportVerificationError.unsafeParent }
    do {
      try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
        fileDescriptor: parentDescriptor,
        path: parentURL.path,
        role: "qualification export parent"
      )
    } catch {
      throw QualificationExportVerificationError.unsafeParent
    }

    let name = outputURL.lastPathComponent
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      throw QualificationExportVerificationError.unsafeOutput
    }
    let descriptor = openat(
      parentDescriptor,
      name,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw QualificationExportVerificationError.unsafeOutput
    }
    defer { close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == owner,
      before.st_nlink == 1,
      before.st_mode & mode_t(0o7777) == 0o600,
      before.st_size > 0,
      before.st_size <= off_t(maximumBytes)
    else { throw QualificationExportVerificationError.unsafeOutput }
    do {
      try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
        fileDescriptor: descriptor,
        path: path,
        role: "qualification export output"
      )
    } catch {
      throw QualificationExportVerificationError.unsafeOutput
    }

    var data = Data(count: Int(before.st_size))
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = pread(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset,
          off_t(offset)
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw QualificationExportVerificationError.unsafeOutput
        }
        offset += count
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    else { throw QualificationExportVerificationError.outputChanged }

    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return QualificationExportVerification(
      data: data,
      sha256: digest,
      bytes: UInt64(data.count)
    )
  }

  private static func isLexicallyCanonicalAbsolute(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return components.first?.isEmpty == true && components.count > 1
      && components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

import Darwin
import Foundation
import HostwrightCore

public enum ControlUnaryInputError: Error, Equatable, Sendable {
  case unexpectedDescriptor
  case tooLarge
  case unsupported
}

public final class OwnedInputDescriptor: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32
  private var consumed = false
  private var consumer: String?
  private var authorizationCheck: (@Sendable () throws -> Void)?

  public init(adopting descriptor: Int32) throws {
    guard descriptor >= 0 else { throw ControlTransportError.invalidDescriptor }
    let flags = fcntl(descriptor, F_GETFD)
    guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
      _ = Darwin.close(descriptor)
      throw ControlTransportError.invalidDescriptor
    }
    self.descriptor = descriptor
  }

  deinit { close() }

  public func close() {
    lock.lock()
    defer { lock.unlock() }
    if descriptor >= 0 { _ = Darwin.close(descriptor); descriptor = -1 }
  }

  public func bindConsumer(_ identity: String) throws {
    lock.lock()
    defer { lock.unlock() }
    guard descriptor >= 0, consumer == nil || consumer == identity else {
      throw ControlUnaryInputError.unexpectedDescriptor
    }
    consumer = identity
  }

  func setAuthorizationCheck(_ check: @escaping @Sendable () throws -> Void) {
    lock.lock()
    defer { lock.unlock() }
    authorizationCheck = check
  }

  public func read(maximumBytes: Int, deadline: ControlTransportDeadline) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard descriptor >= 0, !consumed, consumer != nil,
      (1...65_536).contains(maximumBytes) else {
      throw ControlUnaryInputError.unexpectedDescriptor
    }
    consumed = true
    func assertActive() throws {
      if HostwrightCancellationContext.token?.isCancelled == true { throw CancellationError() }
      try deadline.assertActive()
    }
    try assertActive()
    try authorizationCheck?()
    try assertActive()
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, flags & O_ACCMODE != O_WRONLY else {
      throw ControlTransportError.invalidDescriptor
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFIFO
        || isatty(descriptor) == 1 else { throw ControlTransportError.invalidDescriptor }
    guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw ControlTransportError.ioFailure
    }
    defer { _ = fcntl(descriptor, F_SETFL, flags) }
    let terminal = isatty(descriptor) == 1
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      try assertActive()
      let remaining = try deadline.remainingTimeInterval()
      var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&entry, 1, Int32(max(1, min(50, Int(ceil(remaining * 1_000))))))
      if ready < 0 {
        if errno == EINTR { continue }
        throw ControlTransportError.ioFailure
      }
      if ready == 0 { continue }
      try assertActive()
      guard entry.revents & Int16(POLLERR | POLLNVAL) == 0 else {
        throw ControlTransportError.ioFailure
      }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      let readError = errno
      try assertActive()
      if count < 0 {
        if readError == EINTR || readError == EAGAIN || readError == EWOULDBLOCK { continue }
        throw ControlTransportError.ioFailure
      }
      if count == 0 { try authorizationCheck?(); try assertActive(); return result }
      let bytes = buffer.prefix(count)
      let accepted = terminal ? bytes.prefix { $0 != 10 && $0 != 13 } : bytes[...]
      guard accepted.count <= maximumBytes - result.count else {
        throw ControlUnaryInputError.tooLarge
      }
      result.append(contentsOf: accepted)
      if terminal && accepted.count < bytes.count { try authorizationCheck?(); try assertActive(); return result }
    }
  }
}

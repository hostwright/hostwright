import Darwin
import Foundation
import HostwrightControlPlane

public enum ControlTransportError: Error, Equatable, Sendable {
  case invalidDescriptor
  case invalidDeadline
  case invalidPayloadLength
  case declaredLengthOutOfBounds
  case deadlineExceeded
  case peerClosed
  case writeClosed
  case ioFailure
}

typealias ControlFrameWriteOperation = @Sendable (
  Data,
  ControlPayloadKind,
  Int32,
  ControlTransportDeadline
) throws -> Void

let defaultControlFrameWrite: ControlFrameWriteOperation = {
  try ControlFrameCodec.write($0, kind: $1, descriptor: $2, deadline: $3)
}

public struct ControlTransportDeadline: Sendable {
  private let endUptimeNanoseconds: UInt64
  private let monotonicNow: @Sendable () -> UInt64

  public init(
    timeoutMilliseconds: Int,
    monotonicNow: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    }
  ) throws {
    guard timeoutMilliseconds > 0,
      timeoutMilliseconds <= ControlPlaneContract.maximumUnaryDeadlineMilliseconds
    else {
      throw ControlTransportError.invalidDeadline
    }
    let duration = UInt64(timeoutMilliseconds) * 1_000_000
    let now = monotonicNow()
    guard UInt64.max - now >= duration else {
      throw ControlTransportError.invalidDeadline
    }
    endUptimeNanoseconds = now + duration
    self.monotonicNow = monotonicNow
  }

  public func assertActive() throws {
    guard monotonicNow() < endUptimeNanoseconds else {
      throw ControlTransportError.deadlineExceeded
    }
  }

  func capped(toMilliseconds timeoutMilliseconds: Int) throws -> ControlTransportDeadline {
    guard timeoutMilliseconds > 0,
      timeoutMilliseconds <= ControlPlaneContract.maximumUnaryDeadlineMilliseconds
    else { throw ControlTransportError.invalidDeadline }
    let now = monotonicNow()
    guard now < endUptimeNanoseconds else { throw ControlTransportError.deadlineExceeded }
    let duration = UInt64(timeoutMilliseconds) * 1_000_000
    guard UInt64.max - now >= duration else { throw ControlTransportError.invalidDeadline }
    return ControlTransportDeadline(
      endUptimeNanoseconds: min(endUptimeNanoseconds, now + duration),
      monotonicNow: monotonicNow
    )
  }

  func remainingTimeInterval() throws -> TimeInterval {
    let now = monotonicNow()
    guard now < endUptimeNanoseconds else { throw ControlTransportError.deadlineExceeded }
    return TimeInterval(endUptimeNanoseconds - now) / 1_000_000_000
  }

  private init(
    endUptimeNanoseconds: UInt64,
    monotonicNow: @escaping @Sendable () -> UInt64
  ) {
    self.endUptimeNanoseconds = endUptimeNanoseconds
    self.monotonicNow = monotonicNow
  }

  fileprivate func remainingPollMilliseconds() throws -> Int32 {
    let now = monotonicNow()
    guard now < endUptimeNanoseconds else {
      throw ControlTransportError.deadlineExceeded
    }
    let remainingNanoseconds = endUptimeNanoseconds - now
    let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
    return Int32(min(roundedMilliseconds, UInt64(Int32.max)))
  }
}

public enum ControlFrameCodec {
  public static let prefixBytes = ControlFramingContract.lengthPrefixBytes
  public static let maximumRequestBytes = ControlPlaneContract.maximumRequestBytes
  public static let maximumResponseOrFrameBytes = ControlPlaneContract.maximumResponseOrFrameBytes

  public static func configureNoSigPipe(descriptor: Int32) throws {
    guard descriptor >= 0 else {
      throw ControlTransportError.invalidDescriptor
    }
    var enabled: Int32 = 1
    guard
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      throw ControlTransportError.ioFailure
    }
  }

  public static func configureConnectedSocket(descriptor: Int32) throws {
    try configureNoSigPipe(descriptor: descriptor)
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw ControlTransportError.ioFailure
    }
  }

  public static func waitForFrame(descriptor: Int32) throws {
    guard descriptor >= 0 else {
      throw ControlTransportError.invalidDescriptor
    }
    var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    while true {
      let result = Darwin.poll(&entry, 1, -1)
      if result > 0 {
        guard entry.revents & Int16(POLLNVAL | POLLERR) == 0 else {
          throw ControlTransportError.ioFailure
        }
        if entry.revents & Int16(POLLIN) != 0 { return }
        if entry.revents & Int16(POLLHUP) != 0 { throw ControlTransportError.peerClosed }
        throw ControlTransportError.ioFailure
      }
      if errno == EINTR { continue }
      throw ControlTransportError.ioFailure
    }
  }

  public static func encodedFrame(
    payload: Data,
    kind: ControlPayloadKind
  ) throws -> Data {
    guard payload.count <= Int(UInt32.max) else {
      throw ControlTransportError.invalidPayloadLength
    }
    try validateDeclaredLength(UInt32(payload.count), kind: kind)
    var prefix = UInt32(payload.count).bigEndian
    var frame = Data()
    withUnsafeBytes(of: &prefix) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
  }

  public static func write(
    _ payload: Data,
    kind: ControlPayloadKind,
    descriptor: Int32,
    deadline: ControlTransportDeadline
  ) throws {
    let frame = try encodedFrame(payload: payload, kind: kind)
    try writeAll(frame, descriptor: descriptor, deadline: deadline)
  }

  public static func read(
    kind: ControlPayloadKind,
    descriptor: Int32,
    deadline: ControlTransportDeadline
  ) throws -> Data {
    let frame = try readWithInputDescriptor(kind: kind, descriptor: descriptor, deadline: deadline)
    guard frame.input == nil else {
      frame.input?.close()
      throw ControlUnaryInputError.unexpectedDescriptor
    }
    return frame.payload
  }

  public static func write(
    _ payload: Data, kind: ControlPayloadKind, descriptor: Int32,
    inputDescriptor: Int32, deadline: ControlTransportDeadline
  ) throws {
    guard kind == .request, inputDescriptor >= 0 else {
      throw ControlUnaryInputError.unexpectedDescriptor
    }
    let frame = try encodedFrame(payload: payload, kind: kind)
    let headerSize = MemoryLayout<cmsghdr>.size
    let controlSize = headerSize + MemoryLayout<Int32>.size
    let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: MemoryLayout<cmsghdr>.alignment)
    defer { control.deallocate() }
    control.initializeMemory(as: UInt8.self, repeating: 0, count: controlSize)
    control.storeBytes(of: cmsghdr(cmsg_len: socklen_t(controlSize), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS), as: cmsghdr.self)
    control.advanced(by: headerSize).storeBytes(of: inputDescriptor, as: Int32.self)
    var byte = frame[frame.startIndex]
    while true {
      try waitForWrite(descriptor: descriptor, deadline: deadline)
      let sent = withUnsafeMutablePointer(to: &byte) { pointer in
        var vector = iovec(iov_base: pointer, iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
          var message = msghdr()
          message.msg_iov = vectorPointer; message.msg_iovlen = 1
          message.msg_control = control; message.msg_controllen = socklen_t(controlSize)
          return Darwin.sendmsg(descriptor, &message, 0)
        }
      }
      if sent == 1 { break }
      if sent < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
      throw ControlTransportError.ioFailure
    }
    try writeAll(Data(frame.dropFirst()), descriptor: descriptor, deadline: deadline)
  }

  public static func readWithInputDescriptor(
    kind: ControlPayloadKind, descriptor: Int32, deadline: ControlTransportDeadline
  ) throws -> (payload: Data, input: OwnedInputDescriptor?) {
    var input: OwnedInputDescriptor?
    do {
      let first = try receiveExactly(1, descriptor: descriptor, deadline: deadline, acceptsInput: kind == .request)
      input = first.input
      var prefix = first.payload
      prefix.append(try readExactly(prefixBytes - 1, descriptor: descriptor, deadline: deadline))
      let declaredLength = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
      try validateDeclaredLength(declaredLength, kind: kind)
      return (try readExactly(Int(declaredLength), descriptor: descriptor, deadline: deadline), input)
    } catch { input?.close(); throw error }
  }

  public static func validateDeclaredLength(
    _ length: UInt32,
    kind: ControlPayloadKind
  ) throws {
    let maximum = kind == .request ? maximumRequestBytes : maximumResponseOrFrameBytes
    guard length > 0, length <= UInt32(maximum) else {
      throw ControlTransportError.declaredLengthOutOfBounds
    }
  }

  private static func readExactly(
    _ length: Int,
    descriptor: Int32,
    deadline: ControlTransportDeadline
  ) throws -> Data {
    try receiveExactly(length, descriptor: descriptor, deadline: deadline, acceptsInput: false).payload
  }

  private static func receiveExactly(
    _ length: Int, descriptor: Int32, deadline: ControlTransportDeadline, acceptsInput: Bool
  ) throws -> (payload: Data, input: OwnedInputDescriptor?) {
    guard descriptor >= 0 else { throw ControlTransportError.invalidDescriptor }
    var result = Data(count: length)
    var offset = 0
    var received: [Int32] = []
    var transferred = false
    defer { if !transferred { received.forEach { _ = Darwin.close($0) } } }
    try result.withUnsafeMutableBytes { destination in
      while offset < length {
        try waitForRead(descriptor: descriptor, deadline: deadline)
        let capacity = 256
        let control = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        control.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        var vector = iovec(iov_base: destination.baseAddress!.advanced(by: offset), iov_len: length - offset)
        var message = msghdr()
        let count = withUnsafeMutablePointer(to: &vector) { pointer in
          message.msg_iov = pointer; message.msg_iovlen = 1
          message.msg_control = control; message.msg_controllen = socklen_t(capacity)
          return Darwin.recvmsg(descriptor, &message, 0)
        }
        if count < 0 {
          if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
          throw ControlTransportError.ioFailure
        }
        var ancillaryOffset = 0
        while ancillaryOffset + MemoryLayout<cmsghdr>.size <= Int(message.msg_controllen) {
          let header = control.advanced(by: ancillaryOffset).load(as: cmsghdr.self)
          let size = Int(header.cmsg_len)
          guard size >= MemoryLayout<cmsghdr>.size,
            ancillaryOffset + size <= Int(message.msg_controllen),
            header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS,
            (size - MemoryLayout<cmsghdr>.size) % MemoryLayout<Int32>.size == 0 else {
            throw ControlUnaryInputError.unexpectedDescriptor
          }
          let fdCount = (size - MemoryLayout<cmsghdr>.size) / MemoryLayout<Int32>.size
          for index in 0..<fdCount {
            received.append(control.advanced(by: ancillaryOffset + MemoryLayout<cmsghdr>.size + index * MemoryLayout<Int32>.size).load(as: Int32.self))
          }
          let alignment = MemoryLayout<cmsghdr>.alignment
          ancillaryOffset += (size + alignment - 1) & ~(alignment - 1)
        }
        guard message.msg_flags & MSG_CTRUNC == 0,
          received.count <= (acceptsInput ? 1 : 0) else {
          throw ControlUnaryInputError.unexpectedDescriptor
        }
        if count == 0 { throw ControlTransportError.peerClosed }
        offset += count
      }
    }
    let input = try received.isEmpty ? nil : OwnedInputDescriptor(adopting: received.removeFirst())
    transferred = true
    return (result, input)
  }

  private static func writeAll(
    _ data: Data,
    descriptor: Int32,
    deadline: ControlTransportDeadline
  ) throws {
    guard descriptor >= 0 else {
      throw ControlTransportError.invalidDescriptor
    }
    try data.withUnsafeBytes { source in
      guard let baseAddress = source.baseAddress else {
        throw ControlTransportError.ioFailure
      }
      var offset = 0
      while offset < source.count {
        try waitForWrite(descriptor: descriptor, deadline: deadline)
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          source.count - offset
        )
        if count > 0 {
          offset += count
          continue
        }
        if count == 0 {
          throw ControlTransportError.writeClosed
        }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
          continue
        }
        if errno == EPIPE || errno == ECONNRESET || errno == ENOTCONN || errno == ESHUTDOWN {
          throw ControlTransportError.writeClosed
        }
        throw ControlTransportError.ioFailure
      }
    }
  }

  private static func waitForRead(
    descriptor: Int32,
    deadline: ControlTransportDeadline
  ) throws {
    let revents = try poll(
      descriptor: descriptor,
      events: Int16(POLLIN),
      deadline: deadline
    )
    if revents & Int16(POLLIN) != 0 {
      return
    }
    if revents & Int16(POLLHUP) != 0 {
      throw ControlTransportError.peerClosed
    }
    throw ControlTransportError.ioFailure
  }

  private static func waitForWrite(
    descriptor: Int32,
    deadline: ControlTransportDeadline
  ) throws {
    let revents = try poll(
      descriptor: descriptor,
      events: Int16(POLLOUT),
      deadline: deadline
    )
    if revents & Int16(POLLHUP | POLLERR) != 0 {
      throw ControlTransportError.writeClosed
    }
    guard revents & Int16(POLLOUT) != 0 else {
      throw ControlTransportError.ioFailure
    }
  }

  private static func poll(
    descriptor: Int32,
    events: Int16,
    deadline: ControlTransportDeadline
  ) throws -> Int16 {
    var entry = pollfd(fd: descriptor, events: events, revents: 0)
    while true {
      let result = Darwin.poll(&entry, 1, try deadline.remainingPollMilliseconds())
      if result > 0 {
        guard entry.revents & Int16(POLLNVAL) == 0 else {
          throw ControlTransportError.ioFailure
        }
        return entry.revents
      }
      if result == 0 {
        throw ControlTransportError.deadlineExceeded
      }
      if errno == EINTR {
        continue
      }
      throw ControlTransportError.ioFailure
    }
  }
}

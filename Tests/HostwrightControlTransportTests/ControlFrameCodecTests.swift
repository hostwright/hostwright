import Darwin
import Foundation
import XCTest

@testable import HostwrightControlTransport

final class ControlFrameCodecTests: XCTestCase {
  func testRoundTripUsesBigEndianLengthPrefix() throws {
    try withSocketPair { writer, reader in
      let payload = Data("{\"a\":1}".utf8)
      try ControlFrameCodec.write(
        payload,
        kind: .request,
        descriptor: writer,
        deadline: try deadline()
      )
      XCTAssertEqual(
        try ControlFrameCodec.read(
          kind: .request,
          descriptor: reader,
          deadline: try deadline()
        ),
        payload
      )
    }
  }

  func testInputDescriptorIsBoundToOneFrameAndNeverAcceptedAsOrdinaryPayload() throws {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: Data([0, 65, 10]))
    try pipe.fileHandleForWriting.close()
    try withSocketPair { writer, reader in
      try ControlFrameCodec.write(Data("first".utf8), kind: .request, descriptor: writer,
        inputDescriptor: pipe.fileHandleForReading.fileDescriptor, deadline: deadline())
      try ControlFrameCodec.write(Data("second".utf8), kind: .request, descriptor: writer, deadline: deadline())
      let first = try ControlFrameCodec.readWithInputDescriptor(kind: .request, descriptor: reader, deadline: deadline())
      XCTAssertEqual(first.payload, Data("first".utf8))
      let input = try XCTUnwrap(first.input)
      try input.bindConsumer("test")
      input.setAuthorizationCheck {}
      XCTAssertEqual(try input.read(maximumBytes: 64, deadline: deadline()), Data([0, 65, 10]))
      XCTAssertThrowsError(try input.read(maximumBytes: 64, deadline: deadline()))
      let second = try ControlFrameCodec.readWithInputDescriptor(kind: .request, descriptor: reader, deadline: deadline())
      XCTAssertNil(second.input)
      XCTAssertEqual(second.payload, Data("second".utf8))
    }
    try withSocketPair { writer, reader in
      try ControlFrameCodec.write(Data("unexpected".utf8), kind: .request, descriptor: writer,
        inputDescriptor: pipe.fileHandleForReading.fileDescriptor, deadline: deadline())
      XCTAssertThrowsError(try ControlFrameCodec.read(kind: .request, descriptor: reader, deadline: deadline())) {
        XCTAssertEqual($0 as? ControlUnaryInputError, .unexpectedDescriptor)
      }
    }
  }

  func testInputDescriptorCannotBeAttachedInsideFrameBody() throws {
    let pipe = Pipe()
    try withSocketPair { writer, reader in
      let payload = Data("body".utf8)
      let frame = try ControlFrameCodec.encodedFrame(payload: payload, kind: .request)
      try writeRaw(Data(frame.prefix(4)), descriptor: writer)
      try ControlFrameCodec.write(payload, kind: .request, descriptor: writer,
        inputDescriptor: pipe.fileHandleForReading.fileDescriptor, deadline: deadline())
      XCTAssertThrowsError(try ControlFrameCodec.readWithInputDescriptor(kind: .request, descriptor: reader, deadline: deadline())) {
        XCTAssertEqual($0 as? ControlUnaryInputError, .unexpectedDescriptor)
      }
    }
  }

  func testRejectsAndClosesMultipleAncillaryDescriptors() throws {
    let pipe = Pipe()
    try withSocketPair { writer, reader in
      let frame = try ControlFrameCodec.encodedFrame(payload: Data("duplicate".utf8), kind: .request)
      let headerSize = MemoryLayout<cmsghdr>.size
      let size = headerSize + 2 * MemoryLayout<Int32>.size
      let control = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<cmsghdr>.alignment)
      defer { control.deallocate() }
      control.initializeMemory(as: UInt8.self, repeating: 0, count: size)
      control.storeBytes(of: cmsghdr(cmsg_len: socklen_t(size), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS), as: cmsghdr.self)
      for index in 0..<2 {
        control.advanced(by: headerSize + index * MemoryLayout<Int32>.size).storeBytes(of: pipe.fileHandleForReading.fileDescriptor, as: Int32.self)
      }
      var byte = frame[0]
      let sent = withUnsafeMutablePointer(to: &byte) { pointer in
        var vector = iovec(iov_base: pointer, iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
          var message = msghdr()
          message.msg_iov = vectorPointer; message.msg_iovlen = 1
          message.msg_control = control; message.msg_controllen = socklen_t(size)
          return Darwin.sendmsg(writer, &message, 0)
        }
      }
      XCTAssertEqual(sent, 1)
      try writeRaw(Data(frame.dropFirst()), descriptor: writer)
      try pipe.fileHandleForReading.close()
      XCTAssertThrowsError(try ControlFrameCodec.readWithInputDescriptor(kind: .request, descriptor: reader, deadline: deadline())) {
        XCTAssertEqual($0 as? ControlUnaryInputError, .unexpectedDescriptor)
      }
      var event = pollfd(fd: pipe.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), revents: 0)
      XCTAssertGreaterThan(Darwin.poll(&event, 1, 100), 0)
      XCTAssertNotEqual(event.revents & Int16(POLLERR | POLLHUP), 0, "both received pipe readers must be closed")
    }
  }

  func testReadsFragmentedPrefixAndBody() throws {
    try withSocketPair { writer, reader in
      let payload = Data("{\"fragmented\":true}".utf8)
      let frame = try ControlFrameCodec.encodedFrame(payload: payload, kind: .request)
      try writeRaw(Data(frame.prefix(1)), descriptor: writer)
      try writeRaw(Data(frame.dropFirst().prefix(4)), descriptor: writer)
      try writeRaw(Data(frame.dropFirst(5)), descriptor: writer)
      XCTAssertEqual(
        try ControlFrameCodec.read(
          kind: .request,
          descriptor: reader,
          deadline: try deadline()
        ),
        payload
      )
    }
  }

  func testRejectsOversizeDeclaredLengthBeforePayloadAllocation() throws {
    try withSocketPair { writer, reader in
      var prefix = UInt32(ControlFrameCodec.maximumRequestBytes + 1).bigEndian
      try withUnsafeBytes(of: &prefix) { try writeRaw(Data($0), descriptor: writer) }
      XCTAssertThrowsError(
        try ControlFrameCodec.read(
          kind: .request,
          descriptor: reader,
          deadline: try deadline()
        )
      ) { error in
        XCTAssertEqual(error as? ControlTransportError, .declaredLengthOutOfBounds)
      }
    }
  }

  func testAcceptsBufferedReadWhenPeerHalfCloses() throws {
    try withSocketPair { writer, reader in
      let payload = Data("{\"halfClose\":true}".utf8)
      try writeRaw(
        try ControlFrameCodec.encodedFrame(payload: payload, kind: .response),
        descriptor: writer
      )
      XCTAssertEqual(shutdown(writer, SHUT_WR), 0)
      XCTAssertEqual(
        try ControlFrameCodec.read(
          kind: .response,
          descriptor: reader,
          deadline: try deadline()
        ),
        payload
      )
    }
  }

  func testReadDeadlineExpiresWithoutPeerData() throws {
    try withSocketPair { _, reader in
      XCTAssertThrowsError(
        try ControlFrameCodec.read(
          kind: .request,
          descriptor: reader,
          deadline: try ControlTransportDeadline(timeoutMilliseconds: 5)
        )
      ) { error in
        XCTAssertEqual(error as? ControlTransportError, .deadlineExceeded)
      }
    }
  }

  func testWriteRejectsPeerCloseWithoutSignal() throws {
    var descriptors = try socketPair()
    defer {
      if descriptors.0 >= 0 { _ = Darwin.close(descriptors.0) }
    }
    try ControlFrameCodec.configureNoSigPipe(descriptor: descriptors.0)
    XCTAssertEqual(Darwin.close(descriptors.1), 0)
    descriptors.1 = -1
    XCTAssertThrowsError(
      try ControlFrameCodec.write(
        Data("{\"write\":true}".utf8),
        kind: .frame,
        descriptor: descriptors.0,
        deadline: try deadline()
      )
    ) { error in
      XCTAssertEqual(error as? ControlTransportError, .writeClosed)
    }
  }

  func testNonReadingUnixPeerExpiresMaximumFrameWriteAtDeadline() throws {
    try withSocketPair { writer, _ in
      try ControlFrameCodec.configureConnectedSocket(descriptor: writer)
      try setSendBuffer(descriptor: writer, bytes: 1_024)
      XCTAssertNotEqual(fcntl(writer, F_GETFL) & O_NONBLOCK, 0)

      let payload = Data(
        repeating: 0xA5,
        count: ControlFrameCodec.maximumResponseOrFrameBytes
      )
      let started = DispatchTime.now().uptimeNanoseconds
      XCTAssertThrowsError(
        try ControlFrameCodec.write(
          payload,
          kind: .frame,
          descriptor: writer,
          deadline: try ControlTransportDeadline(timeoutMilliseconds: 50)
        )
      ) { error in
        XCTAssertEqual(error as? ControlTransportError, .deadlineExceeded)
      }
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
      XCTAssertLessThan(elapsed, 1.0, "a non-reading peer must not strand the writer")
    }
  }

  func testDelayedUnixPeerReadCompletesMaximumFrameOnNonblockingWriter() throws {
    try withSocketPair { writer, reader in
      try ControlFrameCodec.configureConnectedSocket(descriptor: writer)
      try setSendBuffer(descriptor: writer, bytes: 1_024)
      XCTAssertNotEqual(fcntl(writer, F_GETFL) & O_NONBLOCK, 0)

      let payload = Data(
        repeating: 0x5A,
        count: ControlFrameCodec.maximumResponseOrFrameBytes
      )
      let started = DispatchSemaphore(value: 0)
      let finished = DispatchGroup()
      let result = FrameWriteResult()
      let began = DispatchTime.now().uptimeNanoseconds
      finished.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        defer { finished.leave() }
        started.signal()
        do {
          try ControlFrameCodec.write(
            payload,
            kind: .frame,
            descriptor: writer,
            deadline: try ControlTransportDeadline(timeoutMilliseconds: 1_000)
          )
        } catch {
          result.error = error
        }
      }

      XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
      Thread.sleep(forTimeInterval: 0.050)
      XCTAssertEqual(
        try ControlFrameCodec.read(
          kind: .frame,
          descriptor: reader,
          deadline: try ControlTransportDeadline(timeoutMilliseconds: 1_000)
        ),
        payload
      )
      XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
      XCTAssertNil(result.error)
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
      XCTAssertLessThan(elapsed, 1.0, "a delayed reader must release the bounded frame write")
    }
  }

  private func deadline() throws -> ControlTransportDeadline {
    try ControlTransportDeadline(timeoutMilliseconds: 1_000)
  }

  private func withSocketPair(_ body: (Int32, Int32) throws -> Void) throws {
    let descriptors = try socketPair()
    defer {
      _ = Darwin.close(descriptors.0)
      _ = Darwin.close(descriptors.1)
    }
    try ControlFrameCodec.configureNoSigPipe(descriptor: descriptors.0)
    try ControlFrameCodec.configureNoSigPipe(descriptor: descriptors.1)
    try body(descriptors.0, descriptors.1)
  }

  private func socketPair() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw NSError(domain: "ControlFrameCodecTests", code: Int(errno))
    }
    return (descriptors[0], descriptors[1])
  }

  private func setSendBuffer(descriptor: Int32, bytes: Int32) throws {
    var bytes = bytes
    guard setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_SNDBUF,
      &bytes,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
      throw NSError(domain: "ControlFrameCodecTests", code: Int(errno))
    }
  }

  private func writeRaw(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { source in
      guard let baseAddress = source.baseAddress else {
        throw NSError(domain: "ControlFrameCodecTests", code: 1)
      }
      var offset = 0
      while offset < source.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          source.count - offset
        )
        guard count > 0 else {
          throw NSError(domain: "ControlFrameCodecTests", code: Int(errno))
        }
        offset += count
      }
    }
  }
}

private final class FrameWriteResult: @unchecked Sendable {
  private let lock = NSLock()
  private var capturedError: Error?

  var error: Error? {
    get { lock.withLock { capturedError } }
    set { lock.withLock { capturedError = newValue } }
  }
}

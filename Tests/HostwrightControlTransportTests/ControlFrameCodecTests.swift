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

import Darwin
import Foundation
import HostwrightCore
import XCTest
@testable import HostwrightControlTransport

final class OwnedInputDescriptorTests: XCTestCase {
  func testBoundedReadPreservesBinaryAndRestoresSharedFlags() throws {
    let pipe = Pipe()
    let flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
    try pipe.fileHandleForWriting.write(contentsOf: Data([65, 0, 66, 10]))
    try pipe.fileHandleForWriting.close()
    let input = try OwnedInputDescriptor(adopting: dup(pipe.fileHandleForReading.fileDescriptor))
    try input.bindConsumer("secret.create:one")
    XCTAssertThrowsError(try input.bindConsumer("secret.create:two"))
    XCTAssertEqual(try input.read(maximumBytes: 4, deadline: ControlTransportDeadline(timeoutMilliseconds: 1_000)), Data([65, 0, 66, 10]))
    XCTAssertEqual(fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL), flags)
    input.close()
    XCTAssertThrowsError(try input.read(maximumBytes: 4, deadline: ControlTransportDeadline(timeoutMilliseconds: 1_000)))
  }

  func testLimitAndDeadlineRestoreFlagsWithoutReadingGlobalInput() throws {
    for oversize in [true, false] {
      let pipe = Pipe()
      let flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
      if oversize { try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 8)) }
      let input = try OwnedInputDescriptor(adopting: dup(pipe.fileHandleForReading.fileDescriptor))
      try input.bindConsumer("secret.create:test")
      XCTAssertThrowsError(try input.read(maximumBytes: 4, deadline: ControlTransportDeadline(timeoutMilliseconds: 10))) {
        if oversize { XCTAssertEqual($0 as? ControlUnaryInputError, .tooLarge) }
        else { XCTAssertEqual($0 as? ControlTransportError, .deadlineExceeded) }
      }
      XCTAssertEqual(fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL), flags)
    }
  }

  func testCancellationDuringFinalAuthorizationDoesNotReturnInput() throws {
    let pipe = Pipe()
    let flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
    try pipe.fileHandleForWriting.write(contentsOf: Data("private-input".utf8))
    try pipe.fileHandleForWriting.close()
    let input = try OwnedInputDescriptor(adopting: dup(pipe.fileHandleForReading.fileDescriptor))
    defer { input.close() }
    try input.bindConsumer("secret.create:cancelled")
    let token = HostwrightCancellationToken()
    let checks = InputAuthorizationChecks()
    input.setAuthorizationCheck {
      if checks.increment() == 2 { token.cancel() }
    }
    try HostwrightCancellationContext.$token.withValue(token) {
      XCTAssertThrowsError(try input.read(maximumBytes: 64, deadline: ControlTransportDeadline(timeoutMilliseconds: 1_000))) {
        XCTAssertTrue($0 is CancellationError)
      }
    }
    XCTAssertEqual(fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL), flags)
  }
}

private final class InputAuthorizationChecks: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() -> Int {
    lock.lock(); defer { lock.unlock() }
    count += 1
    return count
  }
}

import Darwin
import Foundation
import HostwrightControlPlane

final class ControlUnaryDispatcher: @unchecked Sendable {
  typealias Processor = @Sendable (
    ControlRequestEnvelope
  ) throws -> (response: ControlResponseEnvelope, deadline: ControlTransportDeadline)

  private let descriptor: Int32
  private let context: ControlStreamConnectionContext
  private let processor: Processor
  private let queue = DispatchQueue(
    label: "dev.hostwright.control.unary",
    attributes: .concurrent
  )
  private let group = DispatchGroup()
  private let lock = NSLock()
  private var outstanding = 0
  private var failed = false

  init(
    descriptor: Int32,
    context: ControlStreamConnectionContext,
    processor: @escaping Processor
  ) {
    self.descriptor = descriptor
    self.context = context
    self.processor = processor
  }

  func submit(_ request: ControlRequestEnvelope) throws {
    let admitted = lock.withLock { () -> Bool in
      guard !failed, outstanding < ControlPlaneContract.maximumOutstandingUnary else {
        return false
      }
      outstanding += 1
      return true
    }
    guard admitted else {
      let deadline = try ControlTransportDeadline(
        timeoutMilliseconds: request.timeoutMilliseconds!
      )
      try context.writeResponse(
        ControlResponseEnvelope(
          requestID: request.requestID,
          status: .rejected,
          reasonCode: .concurrencyLimit,
          error: SanitizedError(
            code: "unaryConcurrencyLimit",
            message: "The connection has reached its unary request limit."
          )
        ),
        deadline: deadline
      )
      return
    }
    group.enter()
    queue.async { [self] in
      defer {
        lock.withLock { outstanding -= 1 }
        group.leave()
      }
      do {
        let result = try processor(request)
        try context.writeResponse(result.response, deadline: result.deadline)
      } catch {
        failConnection()
      }
    }
  }

  func drain(timeoutMilliseconds: Int = 5_000) {
    if group.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
      failConnection()
    }
  }

  func cancel() { failConnection() }

  private func failConnection() {
    let shouldShutdown = lock.withLock { () -> Bool in
      if failed { return false }
      failed = true
      return true
    }
    if shouldShutdown { _ = shutdown(descriptor, SHUT_RDWR) }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

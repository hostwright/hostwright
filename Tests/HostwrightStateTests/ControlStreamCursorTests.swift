import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightState

final class ControlStreamCursorTests: XCTestCase {
  func testIssueVerifyPreservesBindingAndSourceCursorWithCanonicalToken() throws {
    let clock = LockedDate(Date(timeIntervalSince1970: 1_754_166_400))
    let keyStore = InMemoryAuditSigningKeyStore()
    let codec = try ControlStreamCursorCodec(keyStore: keyStore, now: { clock.value })
    let binding = try makeBinding()

    let token = try codec.issue(binding: binding, sourceCursor: "event:000042")
    let claims = try codec.verify(token, expectedBinding: binding)

    XCTAssertEqual(claims.binding, binding)
    XCTAssertEqual(claims.sourceCursor, "event:000042")
    XCTAssertEqual(claims.expiresAtEpochSeconds - claims.issuedAtEpochSeconds, 3_600)
    XCTAssertTrue(token.hasPrefix("hwsc1."))

    let components = token.split(separator: ".", omittingEmptySubsequences: false)
    XCTAssertEqual(components.count, 3)
    let canonical = try XCTUnwrap(decodeBase64URL(String(components[1])))
    XCTAssertEqual(canonical, try ControlPlaneCanonicalJSON.encode(claims))
    XCTAssertEqual(encodeBase64URL(canonical), String(components[1]))
    XCTAssertThrowsError(try codec.verify(token + "=", expectedBinding: binding)) { error in
      XCTAssertEqual(error as? ControlStreamCursorError, .invalidCursor)
    }
  }

  func testVerifyDeniesSubjectSourceTargetAndFilterBindingMismatches() throws {
    let keyStore = InMemoryAuditSigningKeyStore()
    let codec = try ControlStreamCursorCodec(
      keyStore: keyStore,
      now: { Date(timeIntervalSince1970: 1_754_166_400) }
    )
    let binding = try makeBinding()
    let token = try codec.issue(binding: binding, sourceCursor: "event:000042")
    let mismatches = [
      try ControlStreamCursorBinding(
        subjectID: "operator", source: .events, target: "project:alpha",
        filter: .object(["severity": .string("warning")])
      ),
      try ControlStreamCursorBinding(
        subjectID: "owner", source: .logs, target: "project:alpha",
        filter: .object(["severity": .string("warning")])
      ),
      try ControlStreamCursorBinding(
        subjectID: "owner", source: .events, target: "project:beta",
        filter: .object(["severity": .string("warning")])
      ),
      try ControlStreamCursorBinding(
        subjectID: "owner", source: .events, target: "project:alpha",
        filter: .object(["severity": .string("error")])
      ),
    ]

    for mismatchedBinding in mismatches {
      XCTAssertThrowsError(try codec.verify(token, expectedBinding: mismatchedBinding)) { error in
        XCTAssertEqual(error as? ControlStreamCursorError, .bindingMismatch)
      }
    }
  }

  func testVerifyRejectsPayloadAndSignatureMutation() throws {
    let keyStore = InMemoryAuditSigningKeyStore()
    let codec = try ControlStreamCursorCodec(
      keyStore: keyStore,
      now: { Date(timeIntervalSince1970: 1_754_166_400) }
    )
    let binding = try makeBinding()
    let token = try codec.issue(binding: binding, sourceCursor: "event:000042")
    let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

    var payloadMutated = parts
    payloadMutated[1] = replaceFirstCharacter(in: payloadMutated[1])
    XCTAssertThrowsError(try codec.verify(payloadMutated.joined(separator: "."), expectedBinding: binding)) {
      XCTAssertEqual($0 as? ControlStreamCursorError, .invalidCursor)
    }

    var signatureMutated = parts
    signatureMutated[2] = replaceFirstCharacter(in: signatureMutated[2])
    XCTAssertThrowsError(try codec.verify(signatureMutated.joined(separator: "."), expectedBinding: binding)) {
      XCTAssertEqual($0 as? ControlStreamCursorError, .invalidCursor)
    }
  }

  func testVerifyRejectsExpiredAndFutureIssuedCursorsAndLifetimeBounds() throws {
    let clock = LockedDate(Date(timeIntervalSince1970: 1_754_166_400))
    let keyStore = InMemoryAuditSigningKeyStore()
    let codec = try ControlStreamCursorCodec(keyStore: keyStore, now: { clock.value })
    let binding = try makeBinding()
    let token = try codec.issue(binding: binding, sourceCursor: "event:000042")

    clock.value = Date(timeIntervalSince1970: 1_754_166_400 + 3_601)
    XCTAssertThrowsError(try codec.verify(token, expectedBinding: binding)) { error in
      XCTAssertEqual(error as? ControlStreamCursorError, .expired)
    }

    clock.value = Date(timeIntervalSince1970: 1_754_166_400 - 301)
    XCTAssertThrowsError(try codec.verify(token, expectedBinding: binding)) { error in
      XCTAssertEqual(error as? ControlStreamCursorError, .expired)
    }

    XCTAssertThrowsError(
      try ControlStreamCursorCodec(keyStore: keyStore, lifetimeSeconds: 59, now: { clock.value })
    ) { error in
      XCTAssertEqual(error as? ControlStreamCursorError, .invalidCursor)
    }
    XCTAssertThrowsError(
      try ControlStreamCursorCodec(keyStore: keyStore, lifetimeSeconds: 86_401, now: { clock.value })
    ) { error in
      XCTAssertEqual(error as? ControlStreamCursorError, .invalidCursor)
    }
  }

  func testIssueRejectsOversizedSourceCursor() throws {
    let keyStore = InMemoryAuditSigningKeyStore()
    let codec = try ControlStreamCursorCodec(
      keyStore: keyStore,
      now: { Date(timeIntervalSince1970: 1_754_166_400) }
    )

    XCTAssertThrowsError(
      try codec.issue(binding: try makeBinding(), sourceCursor: String(repeating: "a", count: 2_049))
    ) { error in
      XCTAssertEqual(error as? ControlStreamCursorError, .invalidCursor)
    }
  }

  func testActiveKeyRotationImmediatelyInvalidatesExistingCursor() throws {
    let keyStore = InMemoryAuditSigningKeyStore()
    let codec = try ControlStreamCursorCodec(
      keyStore: keyStore,
      now: { Date(timeIntervalSince1970: 1_754_166_400) }
    )
    let binding = try makeBinding()
    let oldToken = try codec.issue(binding: binding, sourceCursor: "event:000042")
    let rotatedKey = try keyStore.generateInactiveKey()
    try keyStore.activate(keyID: rotatedKey.keyID)

    XCTAssertThrowsError(try codec.verify(oldToken, expectedBinding: binding)) { error in
      XCTAssertEqual(error as? ControlStreamCursorError, .invalidCursor)
    }
    let replacementToken = try codec.issue(binding: binding, sourceCursor: "event:000043")
    XCTAssertEqual(try codec.verify(replacementToken, expectedBinding: binding).keyID, rotatedKey.keyID)
  }

  private func makeBinding() throws -> ControlStreamCursorBinding {
    try ControlStreamCursorBinding(
      subjectID: "owner",
      source: .events,
      target: "project:alpha",
      filter: .object(["severity": .string("warning")])
    )
  }

  private func replaceFirstCharacter(in value: String) -> String {
    let replacement = value.first == "A" ? "B" : "A"
    return String(replacement) + value.dropFirst()
  }

  private func encodeBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
      base64 += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: base64)
  }
}

private final class LockedDate: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Date

  init(_ date: Date) {
    stored = date
  }

  var value: Date {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      stored = newValue
      lock.unlock()
    }
  }
}

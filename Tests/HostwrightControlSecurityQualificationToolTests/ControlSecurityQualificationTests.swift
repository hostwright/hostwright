import Darwin
import Foundation
import HostwrightControlPlane
import XCTest

@testable import HostwrightControlSecurityQualificationTool

final class ControlSecurityQualificationTests: XCTestCase {
  func testParsesOnlyCompleteAbsoluteServerArguments() throws {
    let command = try ControlSecurityQualificationCommand.parse([
      "server",
      "--signed-client", "/tmp/signed-client",
      "--adhoc-client", "/tmp/adhoc-client",
      "--state-db", "/tmp/state.sqlite",
      "--socket-root", "/tmp/socket-root",
    ])
    XCTAssertEqual(
      command,
      .server(
        signedClientPath: "/tmp/signed-client",
        adHocClientPath: "/tmp/adhoc-client",
        stateDatabasePath: "/tmp/state.sqlite",
        socketRootPath: "/tmp/socket-root"
      )
    )
    XCTAssertThrowsError(
      try ControlSecurityQualificationCommand.parse([
        "server", "--signed-client", "relative", "--adhoc-client", "/a", "--state-db", "/b",
        "--socket-root", "/c",
      ])
    )
    XCTAssertThrowsError(
      try ControlSecurityQualificationCommand.parse([
        "server", "--signed-client", "/a", "--signed-client", "/b", "--state-db", "/c",
        "--socket-root", "/d",
      ])
    )
  }

  func testClientAcceptsOnlyOneAbsoluteSocketPath() throws {
    XCTAssertEqual(
      try ControlSecurityQualificationCommand.parse(["client", "/tmp/control.sock"]),
      .client(socketPath: "/tmp/control.sock", credentialFilePath: nil)
    )
    XCTAssertEqual(
      try ControlSecurityQualificationCommand.parse([
        "client", "/tmp/control.sock", "--credential-file", "/tmp/credential.p256",
      ]),
      .client(socketPath: "/tmp/control.sock", credentialFilePath: "/tmp/credential.p256")
    )
    XCTAssertThrowsError(try ControlSecurityQualificationCommand.parse(["client", "socket.sock"]))
    XCTAssertThrowsError(
      try ControlSecurityQualificationCommand.parse(["client", "/tmp/a", "/tmp/b"]))
    XCTAssertThrowsError(
      try ControlSecurityQualificationCommand.parse([
        "client", "/tmp/control.sock", "--credential", "/tmp/credential.p256",
      ]))
  }

  func testHandshakeFramesRejectOversizeDeclaredLengthsBeforeAllocation() {
    XCTAssertNoThrow(
      try AuthenticationFrameCodec.validateDeclaredLength(
        UInt32(ControlPlaneContract.maximumRequestBytes),
        kind: .request
      ))
    XCTAssertThrowsError(
      try AuthenticationFrameCodec.validateDeclaredLength(
        UInt32(ControlPlaneContract.maximumRequestBytes + 1),
        kind: .request
      )
    ) { error in
      XCTAssertEqual(
        error as? ControlSecurityQualificationError,
        .authenticationHandshakeFailed
      )
    }
  }

  func testClientHandshakeBindingRejectsSocketPidAndCodeHashSubstitution() throws {
    let identity = CodeIdentity(
      signingIdentifier: "hostwright-control",
      codeDirectoryHash: String(repeating: "a", count: 40),
      validationMode: .pinnedAdHoc
    )
    let socket = SocketIdentity(device: 17, inode: 19)
    let challenge = authenticationChallenge(identity: identity, socket: socket, pid: 41)
    XCTAssertNoThrow(
      try ClientHandshakeBindingValidation.validate(
        challenge: challenge,
        pinnedSocket: socket,
        currentSocket: socket,
        clientIdentity: identity,
        effectiveUID: 501,
        effectiveGID: 20,
        processID: 41
      ))
    XCTAssertThrowsError(
      try ClientHandshakeBindingValidation.validate(
        challenge: challenge,
        pinnedSocket: socket,
        currentSocket: SocketIdentity(device: 17, inode: 23),
        clientIdentity: identity,
        effectiveUID: 501,
        effectiveGID: 20,
        processID: 41
      ))
    XCTAssertThrowsError(
      try ClientHandshakeBindingValidation.validate(
        challenge: challenge,
        pinnedSocket: socket,
        currentSocket: socket,
        clientIdentity: identity,
        effectiveUID: 501,
        effectiveGID: 20,
        processID: 42
      ))
    let substitutedIdentity = CodeIdentity(
      signingIdentifier: "hostwright-control",
      codeDirectoryHash: String(repeating: "b", count: 40),
      validationMode: .pinnedAdHoc
    )
    XCTAssertThrowsError(
      try ClientHandshakeBindingValidation.validate(
        challenge: challenge,
        pinnedSocket: socket,
        currentSocket: socket,
        clientIdentity: substitutedIdentity,
        effectiveUID: 501,
        effectiveGID: 20,
        processID: 41
      ))
  }

  func testResultIsBoundedCanonicalAndDoesNotExposeSocketOrNonceFields() throws {
    let result = ControlSecurityQualificationResult(
      signed: ControlSecurityQualificationModeResult(
        mode: "signed",
        subjectID: "phase09-gate2-signed-0123456789abcdef",
        sessionID: "21D62DAE-7B7E-479A-B915-8CFC23F4CD8D",
        nativeCDHashLength: 20,
        credentialProof: "verified",
        revocationStatus: "inactive"
      ),
      adHoc: ControlSecurityQualificationModeResult(
        mode: "adHoc",
        subjectID: "phase09-gate2-adHoc-0123456789abcdef",
        sessionID: "D249B8D3-5127-49E4-B6BC-3AF6AAE42107",
        nativeCDHashLength: 32,
        credentialProof: "not-required",
        revocationStatus: "inactive"
      )
    )
    let first = try result.canonicalJSON()
    let second = try result.canonicalJSON()
    XCTAssertEqual(first, second)
    XCTAssertLessThan(first.count, 1_048_576)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
    XCTAssertEqual(object["qualification"] as? String, "phase09-gate2-live-v1")
    XCTAssertNil(object["socketPath"])
    XCTAssertNil(object["serverNonce"])
    XCTAssertNil(object["auditToken"])
    XCTAssertNil(object["credential"])
  }

  func testServerRejectsSymlinkedSocketRootBeforeOpeningState() throws {
    try withTemporaryDirectory { root in
      let testExecutable = try currentExecutablePath()
      let socketRoot = root.appendingPathComponent("socket-root", isDirectory: true)
      try FileManager.default.createDirectory(
        at: socketRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let symlink = root.appendingPathComponent("socket-link", isDirectory: true)
      try FileManager.default.createSymbolicLink(
        at: symlink,
        withDestinationURL: socketRoot
      )
      let command = try ControlSecurityQualificationCommand.parse([
        "server",
        "--signed-client", testExecutable,
        "--adhoc-client", testExecutable,
        "--state-db", root.appendingPathComponent("state.sqlite").path,
        "--socket-root", symlink.path,
      ])
      XCTAssertThrowsError(try ControlSecurityQualificationRunner.run(command)) { error in
        XCTAssertEqual(error as? ControlSecurityQualificationError, .invalidAbsolutePath)
      }
    }
  }

  func testServerRejectsStateDatabaseOutsideAnExact0700Parent() throws {
    try withTemporaryDirectory { root in
      let testExecutable = try currentExecutablePath()
      let socketRoot = root.appendingPathComponent("socket-root", isDirectory: true)
      let unsafeStateParent = root.appendingPathComponent("unsafe-state", isDirectory: true)
      try FileManager.default.createDirectory(
        at: socketRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.createDirectory(
        at: unsafeStateParent,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o755]
      )
      let command = try ControlSecurityQualificationCommand.parse([
        "server",
        "--signed-client", testExecutable,
        "--adhoc-client", testExecutable,
        "--state-db", unsafeStateParent.appendingPathComponent("state.sqlite").path,
        "--socket-root", socketRoot.path,
      ])
      XCTAssertThrowsError(try ControlSecurityQualificationRunner.run(command))

      let doubledSeparator = try ControlSecurityQualificationCommand.parse([
        "server",
        "--signed-client", testExecutable,
        "--adhoc-client", testExecutable,
        "--state-db", "\(root.path)//state.sqlite",
        "--socket-root", socketRoot.path,
      ])
      XCTAssertThrowsError(try ControlSecurityQualificationRunner.run(doubledSeparator)) { error in
        XCTAssertEqual(error as? ControlSecurityQualificationError, .invalidAbsolutePath)
      }
    }
  }

  func testClientRejectsSymlinkedSocketPathBeforeConnect() throws {
    try withTemporaryDirectory { root in
      let target = root.appendingPathComponent("not-a-socket")
      try Data().write(to: target, options: .withoutOverwriting)
      let link = root.appendingPathComponent("socket-link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      let command = try ControlSecurityQualificationCommand.parse(["client", link.path])
      XCTAssertThrowsError(try ControlSecurityQualificationRunner.run(command)) { error in
        XCTAssertEqual(error as? ControlSecurityQualificationError, .invalidAbsolutePath)
      }
    }
  }

  private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-control-security-qualification-test-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: candidate,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let root = URL(fileURLWithPath: try canonicalPath(candidate.path), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }

  private func canonicalPath(_ path: String) throws -> String {
    let resolved = path.withCString { Darwin.realpath($0, nil) }
    let resolvedPointer = try XCTUnwrap(resolved)
    defer { free(resolvedPointer) }
    return String(cString: resolvedPointer)
  }

  private func currentExecutablePath() throws -> String {
    try canonicalPath(CommandLine.arguments[0])
  }

  private func authenticationChallenge(
    identity: CodeIdentity,
    socket: SocketIdentity,
    pid: Int32
  ) -> ControlPeerCredentialChallenge {
    ControlPeerCredentialChallenge(
      subjectID: "phase09-gate2-adHoc-\(identity.codeDirectoryHash.prefix(16))",
      serverNonce: "MDEyMzQ1Njc4OWFiY2RlZg==",
      daemonGeneration: 1,
      socketDevice: socket.device,
      socketInode: socket.inode,
      peer: UnixPeerIdentity(
        effectiveUID: 501,
        effectiveGID: 20,
        pid: pid,
        pidVersion: 1,
        auditSessionID: 1,
        codeIdentity: identity
      ),
      credentialProofRequired: false
    )
  }
}

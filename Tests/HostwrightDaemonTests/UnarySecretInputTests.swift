import Darwin
import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightSecrets
import HostwrightCore
import XCTest
@testable import HostwrightControlTransport
@testable import HostwrightDaemon

final class UnarySecretInputTests: XCTestCase {
  func testMissingInputNeverFallsBackToDaemonInput() throws {
    var environment = CLIEnvironment.live
    environment.readSecretInput = { XCTFail("daemon global stdin must never be read"); return Data() }
    for arguments in [
      ["secret", "create", "keychain://hostwright.input-test/one"],
      ["secret", "update", "keychain://hostwright.input-test/one"],
      ["registry", "login", "registry.example.com", "--username", "user"],
    ] {
      XCTAssertThrowsError(try HostwrightDaemonControlService.unaryInputEnvironment(
        for: CLICommand.parse(arguments: arguments), input: nil,
        deadline: ControlTransportDeadline(timeoutMilliseconds: 1_000), environment: environment))
    }
  }

  func testInvalidCallerBytesReachCLIValidationWithoutSecretEffects() throws {
    let reference = try HostwrightSecretReference.parse("keychain://hostwright.input-test/one")
    for action in ["create", "update", "login"] {
      for bytes in [Data([0]), Data([255]), Data(repeating: 65, count: 65_537)] + (action == "login" ? [Data()] : []) {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let wrote = expectation(description: "finite input writer")
        DispatchQueue.global().async {
          defer { try? writer.close(); wrote.fulfill() }
          try? writer.write(contentsOf: bytes)
        }
        let input = try OwnedInputDescriptor(adopting: dup(pipe.fileHandleForReading.fileDescriptor))
        input.setAuthorizationCheck {}
        let manager = UnaryInputNoMutationManager(reference: reference)
        var environment = CLIEnvironment.live
        environment.secretManager = { manager }
        environment.registryTransport = { XCTFail("invalid input must not authenticate"); return CLIEnvironment.live.registryTransport() }
        let arguments = action == "login"
          ? ["registry", "login", "registry.example.com", "--username", "user", "--json"]
          : ["secret", action, reference.rawValue, "--json"]
        let scoped = try HostwrightDaemonControlService.unaryInputEnvironment(
          for: CLICommand.parse(arguments: arguments), input: input,
          deadline: ControlTransportDeadline(timeoutMilliseconds: 1_000), environment: environment)
        let result = HostwrightCLI.run(arguments: arguments, environment: scoped)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains(action == "login" ? "HW-REGISTRY-001" : "HW-SECRET-001"))
        XCTAssertEqual(manager.metadata.version, 4)
        input.close()
        wait(for: [wrote], timeout: 2)
      }
    }
  }

  func testCancellationKeepsExistingSecretAndRegistryDiagnostics() throws {
    let token = HostwrightCancellationToken()
    token.cancel()
    for arguments in [
      ["secret", "create", "keychain://hostwright.input-test/one", "--json"],
      ["registry", "login", "registry.example.com", "--username", "user", "--json"],
    ] {
      let pipe = Pipe()
      let input = try OwnedInputDescriptor(adopting: dup(pipe.fileHandleForReading.fileDescriptor))
      input.setAuthorizationCheck {}
      let scoped = try HostwrightDaemonControlService.unaryInputEnvironment(
        for: CLICommand.parse(arguments: arguments), input: input,
        deadline: ControlTransportDeadline(timeoutMilliseconds: 1_000), environment: .live)
      let result = HostwrightCancellationContext.$token.withValue(token) {
        HostwrightCLI.run(arguments: arguments, environment: scoped)
      }
      XCTAssertNotEqual(result.exitCode, 0)
      XCTAssertTrue(result.standardError.contains(arguments[0] == "registry" ? "HW-REGISTRY-006" : "HW-SECRET-006"))
    }
  }

  func testEachAllowedCommandUsesExactRequestInputAndRejectsRetargeting() throws {
    for arguments in [
      ["secret", "create", "keychain://hostwright.input-test/one"],
      ["secret", "update", "keychain://hostwright.input-test/one"],
      ["registry", "login", "registry.example.com", "--username", "user"],
    ] {
      let pipe = Pipe()
      try pipe.fileHandleForWriting.write(contentsOf: Data([65, 0, 66]))
      try pipe.fileHandleForWriting.close()
      let input = try OwnedInputDescriptor(adopting: dup(pipe.fileHandleForReading.fileDescriptor))
      input.setAuthorizationCheck {}
      let scoped = try HostwrightDaemonControlService.unaryInputEnvironment(
        for: CLICommand.parse(arguments: arguments), input: input,
        deadline: ControlTransportDeadline(timeoutMilliseconds: 1_000), environment: .live)
      XCTAssertEqual(try scoped.readSecretInput(), Data([65, 0, 66]))
      XCTAssertThrowsError(try HostwrightDaemonControlService.unaryInputEnvironment(
        for: CLICommand.parse(arguments: ["secret", "create", "keychain://hostwright.input-test/other"]), input: input,
        deadline: ControlTransportDeadline(timeoutMilliseconds: 1_000), environment: .live))
      XCTAssertThrowsError(try HostwrightDaemonControlService.unaryInputEnvironment(
        for: CLICommand.parse(arguments: ["secret", "list"]), input: input,
        deadline: ControlTransportDeadline(timeoutMilliseconds: 1_000), environment: .live))
    }
  }
}

private final class UnaryInputNoMutationManager: SecretManager, @unchecked Sendable {
  let metadata: SecretMetadata
  init(reference: HostwrightSecretReference) {
    metadata = SecretMetadata(reference: reference, version: 4, createdAt: Date(), updatedAt: Date(),
      accessibility: .whenUnlockedThisDeviceOnly, synchronizable: false)
  }
  func readString(reference: HostwrightSecretReference) throws -> String { XCTFail("no value read expected"); throw SecretStoreError.cancelled("unexpected read") }
  func check(reference: HostwrightSecretReference) throws -> SecretMetadata { metadata }
  func listMetadata() throws -> [SecretMetadata] { [metadata] }
  func create(reference: HostwrightSecretReference, value: HostwrightSecretValue, itemID: UUID) throws -> SecretMetadata {
    XCTFail("invalid input reached create"); throw SecretStoreError.cancelled("unexpected mutation")
  }
  func update(reference: HostwrightSecretReference, value: HostwrightSecretValue, expectedItemID: UUID) throws -> SecretMetadata {
    XCTFail("invalid input reached update"); throw SecretStoreError.cancelled("unexpected mutation")
  }
  func delete(reference: HostwrightSecretReference, expectedItemID: UUID) throws { XCTFail("no deletion expected") }
}

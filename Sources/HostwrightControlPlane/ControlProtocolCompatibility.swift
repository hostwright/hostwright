import Foundation

/// Compatibility rules for the additive 2.2 control envelope revision.
///
/// Authentication intentionally remains the frozen 2.1 subprotocol. There is
/// no client hello in the existing handshake, so changing its revision would
/// make an N-1 client fail before it can send a request.
public enum ControlProtocolCompatibility {
  public static let previousRevision = ControlProtocolRevision.previous
  public static let currentRevision = ControlProtocolRevision.current
  public static let frozenAuthenticationRevision = ControlProtocolRevision.previous
  public static let frozenAuthenticationProtocolLabel =
    "hostwright-control-credential-proof-v2.1"

  public static func supportsRequestRevision(_ revision: ControlProtocolRevision) -> Bool {
    revision == .previous || revision == .current
  }

  public static func supportsResponseRevision(_ revision: ControlProtocolRevision) -> Bool {
    supportsRequestRevision(revision)
  }

  public static func supportsStreamRevision(_ revision: ControlProtocolRevision) -> Bool {
    supportsRequestRevision(revision)
  }

  public static func requiredRevision(for operation: String) -> ControlProtocolRevision? {
    switch operation {
    case "scheduler.status", "scheduler.plan", "scheduler.simulate",
      "scheduler.explain", "scheduler.apply":
      return .current
    default:
      return nil
    }
  }

  public static func acceptsRequest(
    operation: String,
    revision: ControlProtocolRevision
  ) -> Bool {
    guard supportsRequestRevision(revision) else { return false }
    guard let required = requiredRevision(for: operation) else { return true }
    return revision == required
  }

  public static func validateAuthenticationRevision(
    _ revision: ControlProtocolRevision
  ) throws {
    guard revision == frozenAuthenticationRevision else {
      throw ContractValidationError.unsupportedVersion("control authentication")
    }
  }

  public static func credentialProofLabel(
    for revision: ControlProtocolRevision
  ) -> String? {
    revision == frozenAuthenticationRevision ? frozenAuthenticationProtocolLabel : nil
  }
}

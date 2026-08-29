import Darwin
import Foundation
import HostwrightControlPlane

public enum PluginCLISourceKind: String, Equatable, Sendable {
  case localDirectory, httpsRegistry
}

public struct PluginCLISource: Equatable, Sendable {
  public let kind: PluginCLISourceKind
  public let locator: String

  public init(kind: PluginCLISourceKind, locator: String) {
    self.kind = kind
    self.locator = locator
  }
}

public enum PluginCLIAction: Equatable, Sendable {
  case list(identifier: String?)
  case status(identifier: String?, packageDigest: String?)
  case discover(source: PluginCLISource, signerIdentifier: String)
  case install(source: PluginCLISource, signerIdentifier: String)
  case update(source: PluginCLISource, signerIdentifier: String)
  case activate(packageDigest: String, expectedActivationGeneration: Int?)
  case rollback(identifier: String, expectedActivationGeneration: Int?)
  case revoke(revocationID: String, targetKind: String, targetIdentifier: String, reason: String)
  case quarantine(
    quarantineID: String, packageDigest: String, reasonCode: String, detailDigest: String)
  case uninstall(packageDigest: String, expectedGeneration: Int)
}

public struct PluginCLIOptions: Equatable, Sendable {
  public let action: PluginCLIAction
  public let output: CLIOutputFormat

  public init(action: PluginCLIAction, output: CLIOutputFormat) {
    self.action = action
    self.output = output
  }
}

enum PluginCLIParser {
  static func parse(arguments: [String]) throws -> PluginCLIOptions {
    guard arguments.count >= 2 else {
      throw CLIUsageError(
        "extension requires check, list, status, discover, install, update, activate, rollback, revoke, quarantine, or uninstall.")
    }
    let verb = arguments[1]
    var values: [String: String] = [:]
    var output: CLIOutputFormat = .text
    var outputSelected = false
    var index = 2
    while index < arguments.count {
      let flag = arguments[index]
      if flag == "--json" {
        guard !outputSelected else { throw CLIUsageError("extension output was specified more than once.") }
        output = .json
        outputSelected = true
        index += 1
        continue
      }
      guard index + 1 < arguments.count, flag.hasPrefix("--"), values[flag] == nil else {
        throw CLIUsageError("extension \(verb) contains an invalid or duplicate option.")
      }
      let value = arguments[index + 1]
      guard !value.isEmpty else { throw CLIUsageError("extension \(verb) option values cannot be empty.") }
      if flag == "--output" {
        guard let parsed = CLIOutputFormat(rawValue: value), !outputSelected else {
          throw CLIUsageError("extension output supports only one text or json selection.")
        }
        output = parsed
        outputSelected = true
      } else {
        values[flag] = value
      }
      index += 2
    }
    func exact(_ allowed: Set<String>) throws {
      guard Set(values.keys).isSubset(of: allowed) else {
        throw CLIUsageError("extension \(verb) contains an unsupported option.")
      }
    }
    func required(_ flag: String, maximumBytes: Int = 4_096) throws -> String {
      guard let value = values[flag], value.utf8.count <= maximumBytes else {
        throw CLIUsageError("extension \(verb) requires \(flag) with a bounded value.")
      }
      return value
    }
    func optionalInt(_ flag: String) throws -> Int? {
      guard let raw = values[flag] else { return nil }
      guard let value = Int(raw), value >= 1 else {
        throw CLIUsageError("extension \(verb) requires a positive integer after \(flag).")
      }
      return value
    }
    func source() throws -> PluginCLISource {
      let locator = try required("--source")
      if locator.hasPrefix("https://") {
        guard let url = URL(string: locator), url.host?.isEmpty == false,
          url.user == nil, url.password == nil, url.fragment == nil, url.query == nil
        else { throw CLIUsageError("extension \(verb) --source is invalid.") }
        return PluginCLISource(kind: .httpsRegistry, locator: locator)
      } else {
        do {
          try PluginSource(kind: .localDirectory, locator: locator).validate()
        } catch {
          throw CLIUsageError("extension \(verb) local --source must be a canonical absolute path.")
        }
        guard let resolved = realpath(locator, nil) else {
          throw CLIUsageError("extension \(verb) local --source must resolve to an existing directory.")
        }
        defer { free(resolved) }
        guard String(cString: resolved) == locator else {
          throw CLIUsageError(
            "extension \(verb) local --source must be its exact physical canonical path.")
        }
        return PluginCLISource(kind: .localDirectory, locator: locator)
      }
    }
    func digest(_ flag: String) throws -> String {
      let value = try required(flag, maximumBytes: 71)
      guard value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
        throw CLIUsageError("extension \(verb) requires a sha256 digest after \(flag).")
      }
      return value
    }
    func trustedSourceAction(
      _ constructor: (PluginCLISource, String) -> PluginCLIAction
    ) throws -> PluginCLIAction {
      try exact(["--source", "--signer"])
      return constructor(try source(), try required("--signer", maximumBytes: 256))
    }

    let action: PluginCLIAction
    switch verb {
    case "list":
      try exact(["--identifier"])
      action = .list(identifier: values["--identifier"])
    case "status":
      try exact(["--identifier", "--digest"])
      let identifier = values["--identifier"]
      let packageDigest = try values["--digest"].map { _ in try digest("--digest") }
      guard (identifier == nil) != (packageDigest == nil) else {
        throw CLIUsageError("extension status requires exactly one of --identifier or --digest.")
      }
      action = .status(identifier: identifier, packageDigest: packageDigest)
    case "discover": action = try trustedSourceAction(PluginCLIAction.discover)
    case "install": action = try trustedSourceAction(PluginCLIAction.install)
    case "update": action = try trustedSourceAction(PluginCLIAction.update)
    case "activate":
      try exact(["--digest", "--expected-activation-generation"])
      action = .activate(
        packageDigest: try digest("--digest"),
        expectedActivationGeneration: try optionalInt("--expected-activation-generation"))
    case "rollback":
      try exact(["--identifier", "--expected-activation-generation"])
      action = .rollback(
        identifier: try required("--identifier", maximumBytes: 128),
        expectedActivationGeneration: try optionalInt("--expected-activation-generation"))
    case "revoke":
      try exact(["--revocation-id", "--target-kind", "--target", "--reason"])
      let kind = try required("--target-kind", maximumBytes: 16)
      guard ["package", "signer"].contains(kind) else {
        throw CLIUsageError("extension revoke --target-kind supports package or signer.")
      }
      action = .revoke(
        revocationID: try required("--revocation-id", maximumBytes: 128), targetKind: kind,
        targetIdentifier: try required("--target", maximumBytes: 256),
        reason: try required("--reason", maximumBytes: 1_024))
    case "quarantine":
      try exact(["--quarantine-id", "--digest", "--reason-code", "--detail-digest"])
      action = .quarantine(
        quarantineID: try required("--quarantine-id", maximumBytes: 128),
        packageDigest: try digest("--digest"),
        reasonCode: try required("--reason-code", maximumBytes: 128),
        detailDigest: try digest("--detail-digest"))
    case "uninstall":
      try exact(["--digest", "--expected-generation"])
      guard let generation = try optionalInt("--expected-generation") else {
        throw CLIUsageError("extension uninstall requires --expected-generation.")
      }
      action = .uninstall(packageDigest: try digest("--digest"), expectedGeneration: generation)
    default:
      throw CLIUsageError("extension does not support operation '\(verb)'.")
    }
    return PluginCLIOptions(action: action, output: output)
  }
}

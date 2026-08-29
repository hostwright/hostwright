import Foundation

public enum SchedulerControlOperation: String, Codable, CaseIterable, Sendable {
  case status = "scheduler.status"
  case plan = "scheduler.plan"
  case simulate = "scheduler.simulate"
  case explain = "scheduler.explain"
  case apply = "scheduler.apply"

  public var requiresCurrentRevision: Bool { true }

  /// Planning records an immutable decision artifact that apply can later
  /// reload. Simulation is the only stateless scheduler operation.
  public var isMutating: Bool { self == .plan || self == .apply }
}

/// The daemon-side scheduler bridge has one intentionally narrow body shape.
/// Keeping this contract in ControlPlane avoids a ControlPlane -> Scheduler
/// dependency while still making the wire boundary strict before dispatch.
public enum SchedulerControlWireContract {
  public static let planBodyKeys: Set<String> = ["projectID", "input"]
  public static let decisionBodyKeys: Set<String> = ["projectID", "decisionID"]
  public static let applyBodyKeys: Set<String> = [
    "projectID", "decisionID", "workloadID", "expectedInputDigest",
  ]
  public static let bodyKeys: Set<String> = planBodyKeys
  public static let inputKeys: Set<String> = [
    "inputDigest", "pendingWorkloads", "nodes", "fairnessStates",
    "existingPlacements", "victimAllocations", "disruptionBudgets",
    "antiChurnThresholdBasisPoints", "scoringWeights", "overcommitRatios",
    "preemptionPolicy", "queuePolicy", "stabilityPolicy", "snapshotQuality", "limits",
  ]
  public static let maximumInputBytes = ControlPlaneContract.maximumRequestBytes - 512
  public static let maximumProjectIDBytes = 128
  public static let maximumDigestBytes = 64

  public static func validateOperation(_ operation: String) throws {
    guard SchedulerControlOperation(rawValue: operation) != nil else {
      throw ContractValidationError.invalid("scheduler operation")
    }
  }

  public static func isPlanInputOperation(_ operation: String) -> Bool {
    operation == SchedulerControlOperation.plan.rawValue
      || operation == SchedulerControlOperation.simulate.rawValue
  }

  public static func scopedInputData(
    from body: ControlPlaneJSONValue?
  ) throws -> (projectID: String, inputData: Data) {
    guard case .object(let bodyFields) = body,
      Set(bodyFields.keys) == planBodyKeys,
      case .string(let projectID) = bodyFields["projectID"],
      !projectID.isEmpty,
      projectID.utf8.count <= maximumProjectIDBytes,
      projectID == projectID.trimmingCharacters(in: .whitespacesAndNewlines),
      !projectID.unicodeScalars.contains(where: { $0.value < 0x20 }),
      projectID.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil,
      case .object(let inputFields) = bodyFields["input"],
      Set(inputFields.keys).isSubset(of: inputKeys),
      inputFields["pendingWorkloads"] != nil,
      inputFields["nodes"] != nil
    else {
      throw ContractValidationError.invalid("scheduler input body")
    }
    let data = try ControlPlaneCanonicalJSON.encode(ControlPlaneJSONValue.object(inputFields))
    guard (1...maximumInputBytes).contains(data.count) else {
      throw ContractValidationError.outOfBounds("scheduler input bytes")
    }
    return (projectID, data)
  }

  public static func decisionReference(
    from body: ControlPlaneJSONValue?
  ) throws -> (projectID: String, decisionID: UUID) {
    guard case .object(let fields) = body,
      Set(fields.keys) == decisionBodyKeys else {
      throw ContractValidationError.invalid("scheduler decision body")
    }
    let projectID = try validatedProjectID(fields["projectID"])
    guard case .string(let decisionIDString) = fields["decisionID"],
      let decisionID = UUID(uuidString: decisionIDString) else {
      throw ContractValidationError.invalid("scheduler decision body")
    }
    return (projectID, decisionID)
  }

  public static func applyData(
    from body: ControlPlaneJSONValue?
  ) throws -> (
    projectID: String,
    decisionID: UUID,
    workloadID: UUID,
    expectedInputDigest: String
  ) {
    guard case .object(let fields) = body,
      Set(fields.keys) == applyBodyKeys else {
      throw ContractValidationError.invalid("scheduler apply body")
    }
    let projectID = try validatedProjectID(fields["projectID"])
    guard case .string(let decisionIDValue) = fields["decisionID"],
      let decisionID = UUID(uuidString: decisionIDValue),
      case .string(let workloadIDValue) = fields["workloadID"],
      let workloadID = UUID(uuidString: workloadIDValue),
      case .string(let expectedInputDigest) = fields["expectedInputDigest"],
      expectedInputDigest.utf8.count == maximumDigestBytes,
      expectedInputDigest.unicodeScalars.allSatisfy({
        ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
      }) else {
      throw ContractValidationError.invalid("scheduler apply body")
    }
    guard expectedInputDigest.utf8.count <= maximumDigestBytes else {
      throw ContractValidationError.outOfBounds("scheduler apply body")
    }
    return (projectID, decisionID, workloadID, expectedInputDigest)
  }

  private static func validatedProjectID(
    _ value: ControlPlaneJSONValue?
  ) throws -> String {
    guard case .string(let projectID) = value,
      !projectID.isEmpty,
      projectID.utf8.count <= maximumProjectIDBytes,
      projectID == projectID.trimmingCharacters(in: .whitespacesAndNewlines),
      !projectID.unicodeScalars.contains(where: { $0.value < 0x20 }),
      projectID.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
    else {
      throw ContractValidationError.invalid("scheduler project scope")
    }
    return projectID
  }
}

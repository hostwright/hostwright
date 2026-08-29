import Foundation
import HostwrightControlPlane

@testable import HostwrightControlTransport

let allowingTestControlAdmissionEvaluator: PersistentControlConnectionServer.AdmissionEvaluator = {
  _, request, _ in
  try PersistentControlAdmissionEvaluation(
    effectiveRequest: request, decisions: [], target: request.operation,
    planHash: String(repeating: "a", count: 64), approvalIdentity: nil,
    exceptionIDs: [], allowed: true, reasonCode: "admission.allowed",
    evaluationDigestSHA256: String(repeating: "b", count: 64), dryRun: false)
}

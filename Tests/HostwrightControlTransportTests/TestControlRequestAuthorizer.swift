import Foundation
import HostwrightControlPlane

@testable import HostwrightControlTransport

let allowingTestControlRequestAuthorizer: PersistentControlConnectionServer.Authorizer = {
  _, _, _ in
  RBACDecision(
    effect: .allow,
    ruleIdentifiers: ["test.allow"],
    reasonCode: "authorization.allowed"
  )
}

import Foundation
import HostwrightControlPlane
import HostwrightXPCProvider

let arguments = Array(CommandLine.arguments.dropFirst())
let mode: XPCProviderServiceMode
let serviceName: String
switch arguments.count {
case 0:
  mode = .normal
  serviceName = XPCServiceContract.serviceIdentifier
case 4 where arguments[0] == "--mode" && arguments[2] == "--service-name":
  guard let parsed = XPCProviderServiceMode(rawValue: arguments[1]) else { exit(64) }
  mode = parsed
  serviceName = arguments[3]
default:
  exit(64)
}
XPCProviderServiceRuntime.run(serviceName: serviceName, mode: mode)

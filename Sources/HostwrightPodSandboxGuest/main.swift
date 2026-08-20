import Darwin
import Foundation
import HostwrightPodSandbox

@main
struct HostwrightPodSandboxGuestMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--version"] {
            FileHandle.standardOutput.write(
                Data("hostwright-pod-sandbox-guest-protocol-v1\n".utf8)
            )
            return
        }
        guard arguments == ["--stdio"] else {
            FileHandle.standardError.write(
                Data("hostwright-pod-sandbox-guest: invalid arguments\n".utf8)
            )
            Darwin.exit(EX_USAGE)
        }

        do {
            let dispatcher = GuestAgentDispatcher(
                authenticationBoundary: UnavailableGuestAgentAuthenticationBoundary()
            )
            try GuestAgentServer(dispatcher: dispatcher).run()
        } catch {
            FileHandle.standardError.write(
                Data("hostwright-pod-sandbox-guest: protocol boundary failed\n".utf8)
            )
            Darwin.exit(EX_PROTOCOL)
        }
    }
}

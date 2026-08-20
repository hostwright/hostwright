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
        let recoveryFilePath: String?
        if arguments == ["--stdio"] {
            recoveryFilePath = nil
        } else if arguments.count == 3,
                  arguments[0] == "--stdio",
                  arguments[1] == "--recovery-file",
                  arguments[2].hasPrefix("/") {
            recoveryFilePath = arguments[2]
        } else {
            FileHandle.standardError.write(
                Data("hostwright-pod-sandbox-guest: invalid arguments\n".utf8)
            )
            Darwin.exit(EX_USAGE)
        }

        do {
            let machine: PodSandboxLifecycleStateMachine
            if let recoveryFilePath {
                let store = try FilePodSandboxRecoveryStore(
                    fileURL: URL(fileURLWithPath: recoveryFilePath)
                )
                machine = try PodSandboxLifecycleStateMachine(recoveryStore: store)
            } else {
                machine = PodSandboxLifecycleStateMachine()
            }
            let dispatcher = GuestAgentDispatcher(
                machine: machine,
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

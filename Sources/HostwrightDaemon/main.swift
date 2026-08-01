import Darwin
import Dispatch
import Foundation
import HostwrightCLI
import HostwrightCore
import HostwrightDaemonCore
import HostwrightRuntime

@main
struct HostwrightDaemonEntrypoint {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--service") {
            do {
                let homeDirectory = try DaemonCommand.currentUserHomeDirectory()
                let environment = DaemonCommand.managedServiceEnvironment(
                    homeDirectory: homeDirectory
                )
                if DaemonCommand.managedServiceEnvironmentRequiresReexec(
                    inheritedEnvironment: ProcessInfo.processInfo.environment,
                    homeDirectory: homeDirectory
                ) {
                    try reexecManagedService(environment: environment)
                }
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                Foundation.exit(64)
            }
        }

        let shutdownToken = DaemonShutdownToken()
        let signals = installShutdownSignals(shutdownToken: shutdownToken)
        _ = signals

        let result = await HostwrightDaemonMain.run(
            arguments: arguments,
            runtimeAdapter: RuntimeAdapterFactory.defaultLocal(),
            reconciliationDriver: UnattendedLifecycleReconciler(),
            shutdownToken: shutdownToken
        )

        if !result.standardOutput.isEmpty {
            print(result.standardOutput, terminator: "")
        }
        if !result.standardError.isEmpty {
            FileHandle.standardError.write(Data(result.standardError.utf8))
        }
        Foundation.exit(result.exitCode)
    }

    private static func reexecManagedService(
        environment: [String: String]
    ) throws {
        let executable: SecureExecutableIdentity
        do {
            executable = try SecureExecutableResolver.verify(
                path: CommandLine.arguments[0],
                ownershipPolicy: .rootOrCurrentUser
            )
        } catch {
            throw DaemonError.invalidConfiguration(
                "managed service executable could not be revalidated for environment isolation."
            )
        }

        var allocatedEnvironment: [UnsafeMutablePointer<CChar>] = []
        defer {
            for pointer in allocatedEnvironment {
                free(pointer)
            }
        }
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard let pointer = strdup("\(name)=\(value)") else {
                throw DaemonError.invalidConfiguration(
                    "managed service environment could not be allocated."
                )
            }
            allocatedEnvironment.append(pointer)
        }
        var environmentPointers = allocatedEnvironment.map(Optional.some)
        environmentPointers.append(nil)

        let result = executable.path.withCString { executablePath in
            environmentPointers.withUnsafeMutableBufferPointer { buffer in
                execve(executablePath, CommandLine.unsafeArgv, buffer.baseAddress)
            }
        }
        let failure = errno
        guard result == 0 else {
            throw DaemonError.invalidConfiguration(
                "managed service environment isolation failed (errno \(failure))."
            )
        }
    }

    private static func installShutdownSignals(shutdownToken: DaemonShutdownToken) -> [DispatchSourceSignal] {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let signalQueue = DispatchQueue.global(qos: .userInitiated)

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        intSource.setEventHandler {
            shutdownToken.requestShutdown()
        }
        intSource.resume()

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        termSource.setEventHandler {
            shutdownToken.requestShutdown()
        }
        termSource.resume()

        return [intSource, termSource]
    }
}

import Dispatch
import Foundation
import HostwrightDaemonCore
import HostwrightRuntime

@main
struct HostwrightDaemonEntrypoint {
    static func main() async {
        let shutdownToken = DaemonShutdownToken()
        let signals = installShutdownSignals(shutdownToken: shutdownToken)
        _ = signals

        let result = await HostwrightDaemonMain.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            runtimeAdapter: RuntimeAdapterFactory.defaultReadOnlyLocal(),
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

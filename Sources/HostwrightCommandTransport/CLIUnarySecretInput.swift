import Darwin
import Dispatch
import Foundation
import HostwrightCLI
import HostwrightControlPlane
import HostwrightControlTransport

enum CLIUnarySecretInput {
    static func send(
        socketPath: String,
        request: ControlRequestEnvelope
    ) throws -> ControlResponseEnvelope {
        let input = try HostwrightSecretInputDescriptor()
        let cancellation = PersistentControlRequestCancellation()
        let signals = UnaryInputSignals(cancellation: cancellation)
        defer { signals.stop() }
        do {
            let response = try PersistentControlClient(socketPath: socketPath).send(
                request,
                inputDescriptor: input.descriptor,
                prepareInput: { try input.prepare() },
                cancellation: cancellation
            )
            try input.restore()
            return response
        } catch {
            try input.restore()
            throw error
        }
    }
}

private final class UnaryInputSignals {
    private var sources: [DispatchSourceSignal] = []
    private var previousHandlers: [(Int32, sig_t?)] = []
    private let queue = DispatchQueue(label: "dev.hostwright.cli.unary-input-signals")

    init(cancellation: PersistentControlRequestCancellation) {
        for number in [SIGHUP, SIGINT, SIGQUIT, SIGTERM] {
            previousHandlers.append((number, Darwin.signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            sources.append(source)
        }
    }

    deinit { stop() }

    func stop() {
        for source in sources {
            source.setEventHandler {}
            source.cancel()
        }
        sources.removeAll()
        for (number, handler) in previousHandlers.reversed() {
            Darwin.signal(number, handler)
        }
        previousHandlers.removeAll()
    }
}

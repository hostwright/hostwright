import Darwin
import Foundation
import HostwrightCore

struct ExtensionProcessOutcome: Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitStatus: Int32
    let durationMilliseconds: Int
    let outputOverflowed: Bool
    let errorOverflowed: Bool
}

struct ExtensionHandshakeProcessRunner: Sendable {
    func run(
        executableURL: URL,
        request: Data,
        timeoutMilliseconds: Int,
        maximumOutputBytes: Int
    ) throws -> ExtensionProcessOutcome {
        guard executableURL.path.hasPrefix("/"),
              timeoutMilliseconds > 0,
              maximumOutputBytes > 0 else {
            throw executionFailed("The extension process configuration is invalid.")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["hostwright-extension-handshake-v1"]
        process.environment = ["LANG": "C", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        let output = BoundedExtensionPipe(maximumBytes: maximumOutputBytes)
        let errors = BoundedExtensionPipe(maximumBytes: maximumOutputBytes)
        let readers = DispatchGroup()

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try process.run()
        } catch {
            throw executionFailed("Could not launch the reviewed-local extension process.")
        }

        startReader(outputPipe.fileHandleForReading, destination: output, group: readers)
        startReader(errorPipe.fileHandleForReading, destination: errors, group: readers)

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: request)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            terminate(process: process, terminated: terminated)
            closeReaders(outputPipe: outputPipe, errorPipe: errorPipe)
            _ = readers.wait(timeout: .now() + .seconds(2))
            throw executionFailed("Could not send the bounded handshake request to the extension process.")
        }

        if terminated.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
            terminate(process: process, terminated: terminated)
            closeReaders(outputPipe: outputPipe, errorPipe: errorPipe)
            _ = readers.wait(timeout: .now() + .seconds(2))
            throw executionFailed("The reviewed-local extension handshake timed out.")
        }

        if readers.wait(timeout: .now() + .seconds(2)) == .timedOut {
            closeReaders(outputPipe: outputPipe, errorPipe: errorPipe)
            _ = readers.wait(timeout: .now() + .seconds(2))
            throw executionFailed("The reviewed-local extension output did not close after process exit.")
        }
        guard !output.readFailed, !errors.readFailed else {
            throw executionFailed("Could not read the reviewed-local extension process output.")
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return ExtensionProcessOutcome(
            standardOutput: output.data,
            standardError: errors.data,
            exitStatus: process.terminationStatus,
            durationMilliseconds: Int(clamping: elapsed / 1_000_000),
            outputOverflowed: output.overflowed,
            errorOverflowed: errors.overflowed
        )
    }

    private func startReader(
        _ fileHandle: FileHandle,
        destination: BoundedExtensionPipe,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                do {
                    let chunk = try fileHandle.read(upToCount: 16 * 1_024) ?? Data()
                    guard !chunk.isEmpty else { return }
                    destination.consume(chunk)
                } catch {
                    destination.markReadFailed()
                    return
                }
            }
        }
    }

    private func terminate(process: Process, terminated: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }
        if terminated.wait(timeout: .now() + .seconds(1)) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + .seconds(1))
        }
    }

    private func closeReaders(outputPipe: Pipe, errorPipe: Pipe) {
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
    }

    private func executionFailed(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionExecutionFailed, message: message)
    }
}

private final class BoundedExtensionPipe: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var stored = Data()
    private var didOverflow = false
    private var didFail = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func consume(_ value: Data) {
        lock.withLock {
            let remaining = max(0, maximumBytes - stored.count)
            if remaining > 0 {
                stored.append(value.prefix(remaining))
            }
            if value.count > remaining {
                didOverflow = true
            }
        }
    }

    func markReadFailed() {
        lock.withLock { didFail = true }
    }

    var data: Data {
        lock.withLock { stored }
    }

    var overflowed: Bool {
        lock.withLock { didOverflow }
    }

    var readFailed: Bool {
        lock.withLock { didFail }
    }
}

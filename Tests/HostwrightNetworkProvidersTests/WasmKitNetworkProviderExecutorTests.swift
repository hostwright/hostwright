import Foundation
import XCTest
@testable import HostwrightNetworkProviders

final class WasmKitNetworkProviderExecutorTests: XCTestCase {
    func testWorkerPrintsSPIContractVersion() throws {
        let process = Process()
        process.executableURL = try workerExecutable()
        process.arguments = ["--version"]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            standardOutput.fileHandleForReading.readDataToEndOfFile(),
            Data("network-provider-spi-v1\n".utf8)
        )
        XCTAssertEqual(
            standardError.fileHandleForReading.readDataToEndOfFile(),
            Data()
        )
    }

    func testRealWasmEchoesCanonicalBytesInRestrictedWorker() async throws {
        let executable = try workerExecutable()
        let executor = try WasmKitNetworkProviderExecutor(
            workerExecutableURL: executable
        )
        let input = Data(#"{"nonce":"reference","version":1}"#.utf8)

        let output = try await executor.execute(
            module: referenceModule(),
            stdin: input,
            sandbox: NetworkProviderSandbox()
        )

        XCTAssertEqual(output, input)
    }

    func testRejectsModuleWhoseDeclaredMaximumExceeds64MiB() {
        XCTAssertThrowsError(
            try WasmKitNetworkProviderRuntime.execute(
                moduleBytes: referenceModule(maximumPages: 1_025),
                input: Data(),
                memoryLimitBytes: NetworkProviderSandbox.maximumMemoryBytes,
                outputLimitBytes: NetworkProviderSandbox.maximumOutputBytes
            )
        )
    }

    func testTrapFailsClosed() {
        XCTAssertThrowsError(
            try WasmKitNetworkProviderRuntime.execute(
                moduleBytes: referenceModule(runBody: [0x00, 0x00, 0x0b]),
                input: Data(),
                memoryLimitBytes: NetworkProviderSandbox.maximumMemoryBytes,
                outputLimitBytes: NetworkProviderSandbox.maximumOutputBytes
            )
        )
    }

    func testOutputOverflowFailsClosed() {
        XCTAssertThrowsError(
            try WasmKitNetworkProviderRuntime.execute(
                moduleBytes: referenceModule(),
                input: Data([0x01, 0x02]),
                memoryLimitBytes: NetworkProviderSandbox.maximumMemoryBytes,
                outputLimitBytes: 1
            )
        ) { error in
            XCTAssertEqual(error as? NetworkProviderError, .outputLimitExceeded)
        }
    }

    func testCrashedWorkerFailsClosedAndTemporaryFilesAreRemoved() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let before = try providerTemporaryDirectories(in: temporaryDirectory)
        let executor = try WasmKitNetworkProviderExecutor(
            workerExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
        )

        do {
            _ = try await executor.execute(
                module: referenceModule(),
                stdin: Data(),
                sandbox: NetworkProviderSandbox()
            )
            XCTFail("Expected the crashed worker to fail")
        } catch let error as NetworkProviderError {
            XCTAssertEqual(error, .executionFailed)
        }

        XCTAssertEqual(
            try providerTemporaryDirectories(in: temporaryDirectory),
            before
        )
    }

    func testHungWorkerIsKilledAtDeadlineAndTemporaryFilesAreRemoved() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let before = try providerTemporaryDirectories(in: temporaryDirectory)
        let executor = try WasmKitNetworkProviderExecutor(
            workerExecutableURL: workerExecutable()
        )
        let sandbox = NetworkProviderSandbox(
            memoryLimitBytes: NetworkProviderSandbox.maximumMemoryBytes,
            outputLimitBytes: NetworkProviderSandbox.maximumOutputBytes,
            timeoutMilliseconds: 100
        )

        do {
            _ = try await executor.execute(
                module: referenceModule(
                    runBody: [
                        0x00,
                        0x03,
                        0x40,
                        0x0c,
                        0x00,
                        0x0b,
                        0x42,
                        0x00,
                        0x0b
                    ]
                ),
                stdin: Data(),
                sandbox: sandbox
            )
            XCTFail("Expected the worker deadline to fail")
        } catch {
        }

        XCTAssertEqual(
            try providerTemporaryDirectories(in: temporaryDirectory),
            before
        )
    }

    private func workerExecutable() throws -> URL {
        let candidate = Bundle(for: WasmKitNetworkProviderExecutorTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(WasmKitNetworkProviderExecutor.workerExecutableName)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("Worker executable was not built at \(candidate.path)")
        }
        return candidate
    }

    private func providerTemporaryDirectories(in directory: URL) throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).filter {
                $0.hasPrefix("hostwright-provider-")
            }
        )
    }
}

private func referenceModule(
    maximumPages: UInt64 = 1_024,
    runBody: [UInt8] = [
        0x00,
        0x20,
        0x00,
        0xad,
        0x42,
        0x20,
        0x86,
        0x20,
        0x01,
        0xad,
        0x84,
        0x0b
    ]
) -> Data {
    var module: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
    appendSection(
        id: 1,
        payload: [
            0x02,
            0x60,
            0x01,
            0x7f,
            0x01,
            0x7f,
            0x60,
            0x02,
            0x7f,
            0x7f,
            0x01,
            0x7e
        ],
        to: &module
    )
    appendSection(id: 3, payload: [0x02, 0x00, 0x01], to: &module)
    appendSection(
        id: 5,
        payload: [0x01, 0x01, 0x10] + unsignedLEB(maximumPages),
        to: &module
    )

    var exports: [UInt8] = [0x03]
    appendExport(name: "memory", kind: 0x02, index: 0, to: &exports)
    appendExport(name: "hostwright_alloc", kind: 0x00, index: 0, to: &exports)
    appendExport(name: "hostwright_run", kind: 0x00, index: 1, to: &exports)
    appendSection(id: 7, payload: exports, to: &module)

    let allocateBody: [UInt8] = [0x00, 0x41, 0x00, 0x0b]
    var code: [UInt8] = [0x02]
    code += unsignedLEB(UInt64(allocateBody.count)) + allocateBody
    code += unsignedLEB(UInt64(runBody.count)) + runBody
    appendSection(id: 10, payload: code, to: &module)
    return Data(module)
}

private func appendSection(id: UInt8, payload: [UInt8], to bytes: inout [UInt8]) {
    bytes.append(id)
    bytes += unsignedLEB(UInt64(payload.count))
    bytes += payload
}

private func appendExport(
    name: String,
    kind: UInt8,
    index: UInt64,
    to bytes: inout [UInt8]
) {
    let nameBytes = Array(name.utf8)
    bytes += unsignedLEB(UInt64(nameBytes.count))
    bytes += nameBytes
    bytes.append(kind)
    bytes += unsignedLEB(index)
}

private func unsignedLEB(_ value: UInt64) -> [UInt8] {
    var value = value
    var result: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7f)
        value >>= 7
        if value != 0 {
            byte |= 0x80
        }
        result.append(byte)
    } while value != 0
    return result
}

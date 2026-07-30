import Foundation
import HostwrightNetworkProviders

private func readBoundedStandardInput(maximumBytes: Int) throws -> Data {
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1_024),
          !chunk.isEmpty
    {
        guard chunk.count <= maximumBytes - data.count else {
            throw NetworkProviderError.executionFailed
        }
        data.append(chunk)
    }
    return data
}

private func writeResponse(_ response: WasmWorkerResponse) throws {
    let data = try JSONEncoder().encode(response)
    guard data.count <= WasmKitNetworkProviderExecutor.maximumWorkerResponseBytes else {
        throw NetworkProviderError.outputLimitExceeded
    }
    try FileHandle.standardOutput.write(contentsOf: data)
    try FileHandle.standardOutput.close()
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] {
    print("network-provider-spi-v1")
} else {
    do {
        guard arguments.isEmpty else {
            throw NetworkProviderError.executionFailed
        }
        let requestData = try readBoundedStandardInput(
            maximumBytes: WasmKitNetworkProviderExecutor.maximumWorkerRequestBytes
        )
        let request = try JSONDecoder().decode(
            WasmWorkerRequest.self,
            from: requestData
        )
        let output = try WasmKitNetworkProviderRuntime.execute(
            moduleBytes: request.module,
            input: request.input,
            memoryLimitBytes: request.memoryLimitBytes,
            outputLimitBytes: request.outputLimitBytes
        )
        try writeResponse(WasmWorkerResponse(output: output, error: nil))
    } catch let error as NetworkProviderError {
        try? writeResponse(WasmWorkerResponse(output: nil, error: error))
    } catch {
        try? writeResponse(
            WasmWorkerResponse(output: nil, error: .executionFailed)
        )
    }
}

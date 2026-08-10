import Darwin
import Foundation
import Metal

private struct MetalCellReceipt: Codable {
    let schemaVersion: Int
    let mode: String
    let framework: String
    let status: String
    let evidenceSource: String
    let commandBufferStatus: String
    let resultValidation: String
    let deviceAvailable: Bool
    let input: [UInt32]
    let expected: [UInt32]
    let observed: [UInt32]
    let evidenceScope: String
    let capacityClaim: Bool
    let quotaClaim: Bool
    let reservationClaim: Bool
    let guestPassthroughClaim: Bool
}

private enum MetalCellError: LocalizedError {
    case missingOutputArgument
    case noDevice
    case libraryCompilation(String)
    case missingKernel
    case pipelineCompilation(String)
    case commandQueueUnavailable
    case commandBufferUnavailable
    case computeEncoderUnavailable
    case inputBufferUnavailable
    case outputBufferUnavailable
    case commandFailed(String)
    case resultMismatch(expected: [UInt32], observed: [UInt32])
    case receiptEncoding

    var errorDescription: String? {
        switch self {
        case .missingOutputArgument:
            return "an output receipt path is required"
        case .noDevice:
            return "Metal has no system default device"
        case let .libraryCompilation(message):
            return "Metal shader compilation failed: \(message)"
        case .missingKernel:
            return "compiled Metal library did not contain increment kernel"
        case let .pipelineCompilation(message):
            return "Metal pipeline compilation failed: \(message)"
        case .commandQueueUnavailable:
            return "Metal command queue could not be created"
        case .commandBufferUnavailable:
            return "Metal command buffer could not be created"
        case .computeEncoderUnavailable:
            return "Metal compute encoder could not be created"
        case .inputBufferUnavailable:
            return "Metal input buffer could not be created"
        case .outputBufferUnavailable:
            return "Metal output buffer could not be created"
        case let .commandFailed(status):
            return "Metal command buffer did not complete: \(status)"
        case let .resultMismatch(expected, observed):
            return "Metal kernel result mismatch: expected \(expected), observed \(observed)"
        case .receiptEncoding:
            return "Metal cell receipt could not be encoded"
        }
    }
}

private func run(outputURL: URL) throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw MetalCellError.noDevice
    }

    let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void increment(
        const device uint *input [[buffer(0)]],
        device uint *output [[buffer(1)]],
        uint index [[thread_position_in_grid]]) {
        output[index] = input[index] + 1;
    }
    """

    let library: MTLLibrary
    do {
        library = try device.makeLibrary(source: shaderSource, options: nil)
    } catch {
        throw MetalCellError.libraryCompilation(String(describing: error))
    }

    guard let function = library.makeFunction(name: "increment") else {
        throw MetalCellError.missingKernel
    }

    let pipeline: MTLComputePipelineState
    do {
        pipeline = try device.makeComputePipelineState(function: function)
    } catch {
        throw MetalCellError.pipelineCompilation(String(describing: error))
    }

    let input: [UInt32] = [1, 3, 5, 7]
    let expected: [UInt32] = [2, 4, 6, 8]
    let byteCount = input.count * MemoryLayout<UInt32>.stride

    guard let inputBuffer = device.makeBuffer(
        bytes: input,
        length: byteCount,
        options: .storageModeShared
    ) else {
        throw MetalCellError.inputBufferUnavailable
    }

    guard let outputBuffer = device.makeBuffer(
        length: byteCount,
        options: .storageModeShared
    ) else {
        throw MetalCellError.outputBufferUnavailable
    }

    guard let queue = device.makeCommandQueue() else {
        throw MetalCellError.commandQueueUnavailable
    }

    guard let commandBuffer = queue.makeCommandBuffer() else {
        throw MetalCellError.commandBufferUnavailable
    }

    guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
        throw MetalCellError.computeEncoderUnavailable
    }

    computeEncoder.setComputePipelineState(pipeline)
    computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
    computeEncoder.setBuffer(outputBuffer, offset: 0, index: 1)

    let grid = MTLSize(width: input.count, height: 1, depth: 1)
    let threadgroupWidth = max(1, min(pipeline.threadExecutionWidth, input.count))
    let threadgroup = MTLSize(width: threadgroupWidth, height: 1, depth: 1)
    computeEncoder.dispatchThreads(grid, threadsPerThreadgroup: threadgroup)
    computeEncoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    guard commandBuffer.status == .completed else {
        throw MetalCellError.commandFailed(String(describing: commandBuffer.status))
    }

    let observedPointer = outputBuffer.contents().assumingMemoryBound(to: UInt32.self)
    let observed = Array(UnsafeBufferPointer(start: observedPointer, count: input.count))

    guard observed == expected else {
        throw MetalCellError.resultMismatch(expected: expected, observed: observed)
    }

    let receipt = MetalCellReceipt(
        schemaVersion: 1,
        mode: "metal",
        framework: "Metal",
        status: "passed",
        evidenceSource: "host-native-execution-self-test",
        commandBufferStatus: "completed",
        resultValidation: "exact-output-match",
        deviceAvailable: true,
        input: input,
        expected: expected,
        observed: observed,
        evidenceScope: "inventory-eligibility-only",
        capacityClaim: false,
        quotaClaim: false,
        reservationClaim: false,
        guestPassthroughClaim: false
    )

    let jsonEncoder = JSONEncoder()
    jsonEncoder.outputFormatting = JSONEncoder.OutputFormatting.sortedKeys
    guard let data = try? jsonEncoder.encode(receipt) else {
        throw MetalCellError.receiptEncoding
    }

    try data.write(to: outputURL, options: Data.WritingOptions.atomic)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: phase10-metal-command-buffer-cell OUTPUT_JSON\n".utf8))
    exit(64)
}

do {
    try run(outputURL: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: false))
} catch {
    FileHandle.standardError.write(Data("phase10 Metal cell failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

import Foundation
import HostwrightCore
import HostwrightRuntime

struct ImageCommandRunner {
    let options: ImageCLIOptions
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        switch options.action {
        case .prune, .cacheStatus, .pin, .unpin:
            return try ImageCacheCommandRunner(
                options: options,
                environment: environment
            ).run()
        case .inspect, .pull, .push, .tag, .load, .save, .build,
             .delete:
            break
        }
        let mapped = try mappedInput()
        let stateConfiguration = try hostwrightStateStoreConfiguration(
            explicitPath: options.stateDatabasePath,
            environment: environment
        )
        let execution = try ImageLifecycleCoordinator(
            environment: environment,
            stateStoreConfiguration: stateConfiguration
        ).execute(
            input: mapped.input,
            selection: options.runtimeProvider
        )
        return render(
            execution,
            includeProgress: mapped.progressMode != .none
        )
    }

    private func mappedInput() throws -> MappedImageInput {
        switch options.action {
        case .inspect(let images):
            return MappedImageInput(
                input: ImageLifecycleInput(
                    operation: .inspect,
                    sourceReferences: images
                ),
                progressMode: .plain
            )
        case .pull(
            let reference,
            _,
            let progress,
            let platform,
            let offline
        ):
            return MappedImageInput(
                input: ImageLifecycleInput(
                    operation: .pull,
                    sourceReferences: [reference],
                    platform: platform,
                    offline: offline
                ),
                progressMode: progress
            )
        case .push(
            let reference,
            _,
            let progress,
            let platform,
            let offline
        ):
            return MappedImageInput(
                input: ImageLifecycleInput(
                    operation: .push,
                    sourceReferences: [reference],
                    targetReference: reference,
                    platform: platform,
                    offline: offline
                ),
                progressMode: progress
            )
        case .tag(let source, let target):
            return MappedImageInput(
                input: ImageLifecycleInput(
                    operation: .tag,
                    sourceReferences: [source],
                    targetReference: target
                ),
                progressMode: .plain
            )
        case .load(let inputPath, let expectedReferences):
            return MappedImageInput(
                input: ImageLifecycleInput(
                    operation: .load,
                    sourceReferences: expectedReferences,
                    archivePath: inputPath
                ),
                progressMode: .plain
            )
        case .save(let references, let outputPath, let platform):
            return MappedImageInput(
                input: ImageLifecycleInput(
                    operation: .save,
                    sourceReferences: references,
                    archivePath: outputPath,
                    platform: platform
                ),
                progressMode: .plain
            )
        case .build(
            let contextPath,
            let filePath,
            let tag,
            let platform,
            let noCache,
            let offline
        ):
            return MappedImageInput(
                input: ImageLifecycleInput(
                    operation: .build,
                    targetReference: tag,
                    contextPath: contextPath,
                    dockerfilePath: filePath,
                    platform: platform,
                    offline: offline,
                    noCache: noCache
                ),
                progressMode: .plain
            )
        case .delete(let images):
            return MappedImageInput(
                input: ImageLifecycleInput(
                    operation: .delete,
                    sourceReferences: images
                ),
                progressMode: .plain
            )
        case .prune, .cacheStatus, .pin, .unpin:
            throw HostwrightDiagnostic(
                code: .imageInvalid,
                message:
                    "Image cache operations require the cache coordinator."
            )
        }
    }

    private func render(
        _ execution: ImageLifecycleExecution,
        includeProgress: Bool
    ) -> CLIRunResult {
        let report = ImageOperationReportV1(
            operation: execution.result.operation.rawValue,
            provider: execution.providerID.rawValue,
            providerVersion: execution.result.providerVersion,
            operationID: execution.result.operationID,
            planSHA256: execution.result.planSHA256,
            disposition: execution.result.disposition.rawValue,
            images: execution.result.images,
            createdReferences: execution.createdReferences,
            deletedReferences: execution.deletedReferences,
            deletedDigests: execution.result.deletedDigests,
            progress: includeProgress ? execution.progress : []
        )
        if options.output == .json {
            return CLIRunResult(standardOutput: CLIJSON.codable(report))
        }

        var lines = [
            "image \(report.operation) \(report.disposition)",
            "provider: \(report.provider) \(report.providerVersion)",
            "operation: \(report.operationID)",
            "plan: \(report.planSHA256)"
        ]
        for image in report.images {
            let references = image.references.joined(separator: ",")
            let variants = image.variants.map {
                "\($0.operatingSystem)/\($0.architecture)@\($0.digest)"
            }.joined(separator: ",")
            lines.append(
                "image: \(references) digest=\(image.digest) variants=\(variants)"
            )
        }
        if !report.createdReferences.isEmpty {
            lines.append(
                "created: \(report.createdReferences.joined(separator: ", "))"
            )
        }
        if !report.deletedReferences.isEmpty {
            lines.append(
                "deleted: \(report.deletedReferences.joined(separator: ", "))"
            )
        }
        if includeProgress, !report.progress.isEmpty {
            lines.append(
                "progress: \(report.progress.map(\.stage.rawValue).joined(separator: " -> "))"
            )
        }
        return CLIRunResult(
            standardOutput: lines.joined(separator: "\n") + "\n"
        )
    }
}

private struct MappedImageInput: Sendable {
    let input: ImageLifecycleInput
    let progressMode: ImageCLIProgressMode
}

private struct ImageOperationReportV1: Encodable, Equatable, Sendable {
    let schemaVersion = 1
    let kind = "imageOperation"
    let operation: String
    let provider: String
    let providerVersion: String
    let operationID: String
    let planSHA256: String
    let disposition: String
    let images: [RuntimeImageRecord]
    let createdReferences: [String]
    let deletedReferences: [String]
    let deletedDigests: [String]
    let progress: [RuntimeImageProgressEvent]
}

import Foundation
import HostwrightRuntime

public enum ImageCLIProgressMode: String, Equatable, Sendable {
    case none
    case plain
}

public enum ImageCLIScheme: String, Equatable, Sendable {
    case https
}

public struct ImageCachePruneCLIOptions: Equatable, Sendable {
    public let dryRun: Bool
    public let confirmationPlanSHA256: String?
    public let maximumBytes: Int64?
    public let targetBytes: Int64?
    public let retentionSeconds: Int
    public let maximumDeletions: Int

    public init(
        dryRun: Bool = false,
        confirmationPlanSHA256: String? = nil,
        maximumBytes: Int64? = nil,
        targetBytes: Int64? = nil,
        retentionSeconds: Int = 0,
        maximumDeletions: Int = 256
    ) {
        self.dryRun = dryRun
        self.confirmationPlanSHA256 = confirmationPlanSHA256
        self.maximumBytes = maximumBytes
        self.targetBytes = targetBytes
        self.retentionSeconds = retentionSeconds
        self.maximumDeletions = maximumDeletions
    }
}

public enum ImageCLIAction: Equatable, Sendable {
    case inspect(images: [String])
    case pull(
        reference: String,
        scheme: ImageCLIScheme,
        progress: ImageCLIProgressMode,
        platform: String?,
        offline: Bool
    )
    case push(
        reference: String,
        scheme: ImageCLIScheme,
        progress: ImageCLIProgressMode,
        platform: String?,
        offline: Bool
    )
    case tag(source: String, target: String)
    case load(inputPath: String, expectedReferences: [String])
    case save(references: [String], outputPath: String, platform: String?)
    case build(
        contextPath: String,
        filePath: String?,
        tag: String,
        platform: String?,
        noCache: Bool,
        offline: Bool
    )
    case delete(images: [String])
    case prune(options: ImageCachePruneCLIOptions)
    case cacheStatus(maximumBytes: Int64?)
    case pin(reference: String)
    case unpin(reference: String)
}

public struct ImageCLIOptions: Equatable, Sendable {
    public let action: ImageCLIAction
    public let stateDatabasePath: String?
    public let runtimeProvider: RuntimeProviderSelection
    public let output: CLIOutputFormat

    public init(
        action: ImageCLIAction,
        stateDatabasePath: String?,
        runtimeProvider: RuntimeProviderSelection,
        output: CLIOutputFormat
    ) {
        self.action = action
        self.stateDatabasePath = stateDatabasePath
        self.runtimeProvider = runtimeProvider
        self.output = output
    }
}

enum ImageCLIParser {
    static func parse(arguments: [String]) throws -> ImageCLIOptions {
        guard arguments.count >= 2 else {
            throw CLIUsageError("image requires a subcommand.")
        }
        switch arguments[1] {
        case "inspect":
            return try inspect(arguments: arguments)
        case "pull":
            return try pull(arguments: arguments)
        case "push":
            return try push(arguments: arguments)
        case "tag":
            return try tag(arguments: arguments)
        case "load":
            return try load(arguments: arguments)
        case "save":
            return try save(arguments: arguments)
        case "build":
            return try build(arguments: arguments)
        case "delete", "rm":
            return try delete(arguments: arguments)
        case "prune":
            return try prune(arguments: arguments)
        case "cache":
            return try cache(arguments: arguments)
        default:
            throw CLIUsageError("image supports inspect, pull, push, tag, load, save, build, delete, prune, and cache.")
        }
    }

    private static func inspect(arguments: [String]) throws -> ImageCLIOptions {
        var stateDatabasePath: String?
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var images: [String] = []
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                stateDatabasePath = try uniqueValue(
                    arguments: arguments,
                    index: index,
                    flag: "--state-db",
                    existing: stateDatabasePath,
                    command: "image inspect"
                )
                index += 2
            case "--runtime-provider":
                runtimeProvider = try parseRuntimeProvider(
                    arguments: arguments,
                    index: index,
                    existing: runtimeProvider == .automatic ? nil : runtimeProvider,
                    command: "image inspect"
                )
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError("image inspect output may be selected only once.")
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else {
                    throw CLIUsageError("image inspect output may be selected only once.")
                }
                output = try parseOutput(arguments: arguments, index: index, command: "image inspect")
                outputSelected = true
                index += 2
            default:
                images.append(try imageValue(arguments[index], command: "image inspect"))
                index += 1
            }
        }
        guard !images.isEmpty else {
            throw CLIUsageError("image inspect requires at least one image reference or digest.")
        }
        return ImageCLIOptions(
            action: .inspect(images: images),
            stateDatabasePath: stateDatabasePath,
            runtimeProvider: runtimeProvider,
            output: output
        )
    }

    private static func pull(arguments: [String]) throws -> ImageCLIOptions {
        var stateDatabasePath: String?
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var scheme: ImageCLIScheme = .https
        var schemeSelected = false
        var progress: ImageCLIProgressMode = .plain
        var progressSelected = false
        var platform: String?
        var offline = false
        var reference: String?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                stateDatabasePath = try uniqueValue(arguments: arguments, index: index, flag: "--state-db", existing: stateDatabasePath, command: "image pull")
                index += 2
            case "--runtime-provider":
                runtimeProvider = try parseRuntimeProvider(arguments: arguments, index: index, existing: runtimeProvider == .automatic ? nil : runtimeProvider, command: "image pull")
                index += 2
            case "--scheme":
                guard !schemeSelected else {
                    throw CLIUsageError("image pull accepts --scheme at most once.")
                }
                let value = try requireValue(arguments: arguments, index: index, flag: "--scheme", command: "image pull")
                guard let parsed = ImageCLIScheme(rawValue: value) else {
                    throw CLIUsageError("image pull permits only the explicit https scheme.")
                }
                scheme = parsed
                schemeSelected = true
                index += 2
            case "--progress":
                guard !progressSelected else {
                    throw CLIUsageError("image pull accepts --progress at most once.")
                }
                let value = try requireValue(arguments: arguments, index: index, flag: "--progress", command: "image pull")
                guard let parsed = ImageCLIProgressMode(rawValue: value) else {
                    throw CLIUsageError("image pull --progress supports only none or plain.")
                }
                progress = parsed
                progressSelected = true
                index += 2
            case "--platform":
                platform = try uniqueValue(arguments: arguments, index: index, flag: "--platform", existing: platform, command: "image pull")
                try validatePlatform(platform)
                index += 2
            case "--offline":
                guard !offline else {
                    throw CLIUsageError("image pull accepts --offline at most once.")
                }
                offline = true
                index += 1
            case "--json":
                guard !outputSelected else { throw CLIUsageError("image pull output may be selected only once.") }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else { throw CLIUsageError("image pull output may be selected only once.") }
                output = try parseOutput(arguments: arguments, index: index, command: "image pull")
                outputSelected = true
                index += 2
            default:
                guard reference == nil else {
                    throw CLIUsageError("image pull accepts exactly one image reference.")
                }
                reference = try imageValue(arguments[index], command: "image pull")
                index += 1
            }
        }
        guard let reference else {
            throw CLIUsageError("image pull requires exactly one image reference.")
        }
        return ImageCLIOptions(
            action: .pull(
                reference: reference,
                scheme: scheme,
                progress: progress,
                platform: platform,
                offline: offline
            ),
            stateDatabasePath: stateDatabasePath,
            runtimeProvider: runtimeProvider,
            output: output
        )
    }

    private static func push(arguments: [String]) throws -> ImageCLIOptions {
        var stateDatabasePath: String?
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var scheme: ImageCLIScheme = .https
        var schemeSelected = false
        var progress: ImageCLIProgressMode = .plain
        var progressSelected = false
        var platform: String?
        var offline = false
        var reference: String?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                stateDatabasePath = try uniqueValue(arguments: arguments, index: index, flag: "--state-db", existing: stateDatabasePath, command: "image push")
                index += 2
            case "--runtime-provider":
                runtimeProvider = try parseRuntimeProvider(arguments: arguments, index: index, existing: runtimeProvider == .automatic ? nil : runtimeProvider, command: "image push")
                index += 2
            case "--scheme":
                guard !schemeSelected else {
                    throw CLIUsageError("image push accepts --scheme at most once.")
                }
                let value = try requireValue(arguments: arguments, index: index, flag: "--scheme", command: "image push")
                guard let parsed = ImageCLIScheme(rawValue: value) else {
                    throw CLIUsageError("image push permits only the explicit https scheme.")
                }
                scheme = parsed
                schemeSelected = true
                index += 2
            case "--progress":
                guard !progressSelected else {
                    throw CLIUsageError("image push accepts --progress at most once.")
                }
                let value = try requireValue(arguments: arguments, index: index, flag: "--progress", command: "image push")
                guard let parsed = ImageCLIProgressMode(rawValue: value) else {
                    throw CLIUsageError("image push --progress supports only none or plain.")
                }
                progress = parsed
                progressSelected = true
                index += 2
            case "--platform":
                platform = try uniqueValue(arguments: arguments, index: index, flag: "--platform", existing: platform, command: "image push")
                try validatePlatform(platform)
                index += 2
            case "--offline":
                guard !offline else {
                    throw CLIUsageError("image push accepts --offline at most once.")
                }
                offline = true
                index += 1
            case "--json":
                guard !outputSelected else { throw CLIUsageError("image push output may be selected only once.") }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else { throw CLIUsageError("image push output may be selected only once.") }
                output = try parseOutput(arguments: arguments, index: index, command: "image push")
                outputSelected = true
                index += 2
            default:
                guard reference == nil else {
                    throw CLIUsageError("image push accepts exactly one image reference.")
                }
                reference = try imageValue(arguments[index], command: "image push")
                index += 1
            }
        }
        guard let reference else {
            throw CLIUsageError("image push requires exactly one image reference.")
        }
        return ImageCLIOptions(
            action: .push(
                reference: reference,
                scheme: scheme,
                progress: progress,
                platform: platform,
                offline: offline
            ),
            stateDatabasePath: stateDatabasePath,
            runtimeProvider: runtimeProvider,
            output: output
        )
    }

    private static func tag(arguments: [String]) throws -> ImageCLIOptions {
        let shared = try sharedOptions(arguments: arguments, command: "image tag")
        let positionals = try shared.positionals.map { try imageValue($0, command: "image tag") }
        guard positionals.count == 2 else {
            throw CLIUsageError("image tag requires exactly <source> and <target>.")
        }
        return ImageCLIOptions(
            action: .tag(source: positionals[0], target: positionals[1]),
            stateDatabasePath: shared.stateDatabasePath,
            runtimeProvider: shared.runtimeProvider,
            output: shared.output
        )
    }

    private static func load(arguments: [String]) throws -> ImageCLIOptions {
        var stateDatabasePath: String?
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var inputPath: String?
        var expectedReferences: [String] = []
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                stateDatabasePath = try uniqueValue(arguments: arguments, index: index, flag: "--state-db", existing: stateDatabasePath, command: "image load")
                index += 2
            case "--runtime-provider":
                runtimeProvider = try parseRuntimeProvider(arguments: arguments, index: index, existing: runtimeProvider == .automatic ? nil : runtimeProvider, command: "image load")
                index += 2
            case "--input":
                inputPath = try normalizedPath(
                    uniqueValue(
                        arguments: arguments,
                        index: index,
                        flag: "--input",
                        existing: inputPath,
                        command: "image load"
                    ),
                    command: "image load"
                )
                index += 2
            case "--reference":
                let reference = try requireValue(
                    arguments: arguments,
                    index: index,
                    flag: "--reference",
                    command: "image load"
                )
                expectedReferences.append(
                    try imageValue(reference, command: "image load")
                )
                index += 2
            case "--force":
                throw CLIUsageError("image load never permits native --force.")
            case "--json":
                guard !outputSelected else { throw CLIUsageError("image load output may be selected only once.") }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else { throw CLIUsageError("image load output may be selected only once.") }
                output = try parseOutput(arguments: arguments, index: index, command: "image load")
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError("image load supports only --state-db, --runtime-provider, --input, repeatable --reference, --json, and --output.")
            }
        }
        guard let inputPath else {
            throw CLIUsageError("image load requires --input <path>.")
        }
        guard !expectedReferences.isEmpty,
              Set(expectedReferences).count == expectedReferences.count else {
            throw CLIUsageError(
                "image load requires one or more unique --reference <expected-reference> values."
            )
        }
        return ImageCLIOptions(
            action: .load(
                inputPath: inputPath,
                expectedReferences: expectedReferences.sorted()
            ),
            stateDatabasePath: stateDatabasePath,
            runtimeProvider: runtimeProvider,
            output: output
        )
    }

    private static func save(arguments: [String]) throws -> ImageCLIOptions {
        var stateDatabasePath: String?
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var outputPath: String?
        var platform: String?
        var references: [String] = []
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                stateDatabasePath = try uniqueValue(arguments: arguments, index: index, flag: "--state-db", existing: stateDatabasePath, command: "image save")
                index += 2
            case "--runtime-provider":
                runtimeProvider = try parseRuntimeProvider(arguments: arguments, index: index, existing: runtimeProvider == .automatic ? nil : runtimeProvider, command: "image save")
                index += 2
            case "--output":
                if outputSelected {
                    throw CLIUsageError("image save output format/path may be selected only once per flag.")
                }
                outputPath = try normalizedPath(
                    uniqueValue(
                        arguments: arguments,
                        index: index,
                        flag: "--output",
                        existing: outputPath,
                        command: "image save"
                    ),
                    command: "image save"
                )
                index += 2
            case "--platform":
                platform = try uniqueValue(arguments: arguments, index: index, flag: "--platform", existing: platform, command: "image save")
                try validatePlatform(platform)
                index += 2
            case "--json":
                guard output == .text else { throw CLIUsageError("image save output format may be selected only once.") }
                output = .json
                outputSelected = true
                index += 1
            case "--format":
                throw CLIUsageError("image save does not support --format; use --json or --output text|json.")
            default:
                if arguments[index] == "text" || arguments[index] == "json" {
                    throw CLIUsageError("image save output path must be selected with --output <path>; JSON format uses --json.")
                }
                references.append(try imageValue(arguments[index], command: "image save"))
                index += 1
            }
        }
        guard let outputPath else {
            throw CLIUsageError("image save requires --output <path>.")
        }
        guard !references.isEmpty else {
            throw CLIUsageError("image save requires at least one image reference.")
        }
        return ImageCLIOptions(
            action: .save(references: references, outputPath: outputPath, platform: platform),
            stateDatabasePath: stateDatabasePath,
            runtimeProvider: runtimeProvider,
            output: output
        )
    }

    private static func build(arguments: [String]) throws -> ImageCLIOptions {
        var stateDatabasePath: String?
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var contextPath: String?
        var filePath: String?
        var tag: String?
        var platform: String?
        var noCache = false
        var offline = false
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                stateDatabasePath = try uniqueValue(arguments: arguments, index: index, flag: "--state-db", existing: stateDatabasePath, command: "image build")
                index += 2
            case "--runtime-provider":
                runtimeProvider = try parseRuntimeProvider(arguments: arguments, index: index, existing: runtimeProvider == .automatic ? nil : runtimeProvider, command: "image build")
                index += 2
            case "--file":
                filePath = try normalizedPath(
                    uniqueValue(
                        arguments: arguments,
                        index: index,
                        flag: "--file",
                        existing: filePath,
                        command: "image build"
                    ),
                    command: "image build"
                )
                index += 2
            case "--context":
                contextPath = try normalizedPath(
                    uniqueValue(
                        arguments: arguments,
                        index: index,
                        flag: "--context",
                        existing: contextPath,
                        command: "image build"
                    ),
                    command: "image build"
                )
                index += 2
            case "--tag":
                tag = try uniqueValue(arguments: arguments, index: index, flag: "--tag", existing: tag, command: "image build")
                index += 2
            case "--platform":
                platform = try uniqueValue(arguments: arguments, index: index, flag: "--platform", existing: platform, command: "image build")
                try validatePlatform(platform)
                index += 2
            case "--build-arg":
                throw CLIUsageError("image build rejects build arguments because credential-safe delivery is not available.")
            case "--label":
                throw CLIUsageError("image build labels are not part of the Gate 4 contract.")
            case "--no-cache":
                guard !noCache else { throw CLIUsageError("image build accepts --no-cache at most once.") }
                noCache = true
                index += 1
            case "--quiet":
                throw CLIUsageError("image build controls native output internally and does not accept --quiet.")
            case "--offline":
                guard !offline else {
                    throw CLIUsageError("image build accepts --offline at most once.")
                }
                offline = true
                index += 1
            case "--json":
                guard !outputSelected else { throw CLIUsageError("image build output may be selected only once.") }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else { throw CLIUsageError("image build output may be selected only once.") }
                output = try parseOutput(arguments: arguments, index: index, command: "image build")
                outputSelected = true
                index += 2
            default:
                throw CLIUsageError("image build requires its absolute build directory through --context.")
            }
        }
        guard let contextPath else {
            throw CLIUsageError("image build requires --context <absolute-path>.")
        }
        guard let tag else {
            throw CLIUsageError("image build requires --tag <reference>.")
        }
        if let filePath {
            let prefix = contextPath == "/" ? "/" : contextPath + "/"
            guard filePath.hasPrefix(prefix) else {
                throw CLIUsageError("image build --file must stay inside the exact build context.")
            }
        }
        return ImageCLIOptions(
            action: .build(
                contextPath: contextPath,
                filePath: filePath,
                tag: try imageValue(tag, command: "image build"),
                platform: platform,
                noCache: noCache,
                offline: offline
            ),
            stateDatabasePath: stateDatabasePath,
            runtimeProvider: runtimeProvider,
            output: output
        )
    }

    private static func delete(arguments: [String]) throws -> ImageCLIOptions {
        let shared = try sharedOptions(arguments: arguments, command: "image delete")
        let images = try shared.positionals.map { try imageValue($0, command: "image delete") }
        guard !images.isEmpty else {
            throw CLIUsageError("image delete requires at least one managed image reference or digest.")
        }
        return ImageCLIOptions(
            action: .delete(images: images),
            stateDatabasePath: shared.stateDatabasePath,
            runtimeProvider: shared.runtimeProvider,
            output: shared.output
        )
    }

    private static func prune(arguments: [String]) throws -> ImageCLIOptions {
        var stateDatabasePath: String?
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var dryRun = false
        var confirmationPlanSHA256: String?
        var maximumBytes: Int64?
        var targetBytes: Int64?
        var retentionSeconds = 0
        var retentionSelected = false
        var maximumDeletions = 256
        var maximumDeletionsSelected = false
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                stateDatabasePath = try uniqueValue(
                    arguments: arguments,
                    index: index,
                    flag: "--state-db",
                    existing: stateDatabasePath,
                    command: "image prune"
                )
                index += 2
            case "--runtime-provider":
                runtimeProvider = try parseRuntimeProvider(
                    arguments: arguments,
                    index: index,
                    existing: runtimeProvider == .automatic
                        ? nil
                        : runtimeProvider,
                    command: "image prune"
                )
                index += 2
            case "--dry-run":
                guard !dryRun, confirmationPlanSHA256 == nil else {
                    throw CLIUsageError(
                        "image prune accepts exactly one of --dry-run or --confirm-plan."
                    )
                }
                dryRun = true
                index += 1
            case "--confirm-plan":
                guard !dryRun, confirmationPlanSHA256 == nil else {
                    throw CLIUsageError(
                        "image prune accepts exactly one of --dry-run or --confirm-plan."
                    )
                }
                let value = try requireValue(
                    arguments: arguments,
                    index: index,
                    flag: "--confirm-plan",
                    command: "image prune"
                )
                guard validSHA256(value) else {
                    throw CLIUsageError(
                        "image prune --confirm-plan requires one lowercase SHA-256."
                    )
                }
                confirmationPlanSHA256 = value
                index += 2
            case "--maximum-bytes":
                guard maximumBytes == nil else {
                    throw CLIUsageError(
                        "image prune accepts --maximum-bytes at most once."
                    )
                }
                maximumBytes = try positiveInt64(
                    arguments: arguments,
                    index: index,
                    flag: "--maximum-bytes",
                    command: "image prune"
                )
                index += 2
            case "--target-bytes":
                guard targetBytes == nil else {
                    throw CLIUsageError(
                        "image prune accepts --target-bytes at most once."
                    )
                }
                targetBytes = try nonnegativeInt64(
                    arguments: arguments,
                    index: index,
                    flag: "--target-bytes",
                    command: "image prune"
                )
                index += 2
            case "--retain-seconds":
                guard !retentionSelected else {
                    throw CLIUsageError(
                        "image prune accepts --retain-seconds at most once."
                    )
                }
                retentionSeconds = try boundedInt(
                    arguments: arguments,
                    index: index,
                    flag: "--retain-seconds",
                    command: "image prune",
                    range: 0...31_536_000
                )
                retentionSelected = true
                index += 2
            case "--max-delete":
                guard !maximumDeletionsSelected else {
                    throw CLIUsageError(
                        "image prune accepts --max-delete at most once."
                    )
                }
                maximumDeletions = try boundedInt(
                    arguments: arguments,
                    index: index,
                    flag: "--max-delete",
                    command: "image prune",
                    range: 1...256
                )
                maximumDeletionsSelected = true
                index += 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError(
                        "image prune output may be selected only once."
                    )
                }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else {
                    throw CLIUsageError(
                        "image prune output may be selected only once."
                    )
                }
                output = try parseOutput(
                    arguments: arguments,
                    index: index,
                    command: "image prune"
                )
                outputSelected = true
                index += 2
            case "--all-managed", "--all", "--force":
                throw CLIUsageError(
                    "image prune never permits broad native cleanup selectors."
                )
            default:
                throw CLIUsageError(
                    "image prune does not support argument '\(arguments[index])'."
                )
            }
        }
        guard (maximumBytes == nil) == (targetBytes == nil) else {
            throw CLIUsageError(
                "image prune requires --maximum-bytes and --target-bytes together."
            )
        }
        if let maximumBytes, let targetBytes {
            guard targetBytes <= maximumBytes else {
                throw CLIUsageError(
                    "image prune --target-bytes must not exceed --maximum-bytes."
                )
            }
        }
        return ImageCLIOptions(
            action: .prune(
                options: ImageCachePruneCLIOptions(
                    dryRun: dryRun,
                    confirmationPlanSHA256: confirmationPlanSHA256,
                    maximumBytes: maximumBytes,
                    targetBytes: targetBytes,
                    retentionSeconds: retentionSeconds,
                    maximumDeletions: maximumDeletions
                )
            ),
            stateDatabasePath: stateDatabasePath,
            runtimeProvider: runtimeProvider,
            output: output
        )
    }

    private static func cache(arguments: [String]) throws -> ImageCLIOptions {
        guard arguments.count >= 3 else {
            throw CLIUsageError(
                "image cache requires status, pin, or unpin."
            )
        }
        switch arguments[2] {
        case "status":
            var maximumBytes: Int64?
            var filtered: [String] = Array(arguments.prefix(3))
            var index = 3
            while index < arguments.count {
                if arguments[index] == "--maximum-bytes" {
                    guard maximumBytes == nil else {
                        throw CLIUsageError(
                            "image cache status accepts --maximum-bytes at most once."
                        )
                    }
                    maximumBytes = try positiveInt64(
                        arguments: arguments,
                        index: index,
                        flag: "--maximum-bytes",
                        command: "image cache status"
                    )
                    index += 2
                } else {
                    filtered.append(arguments[index])
                    index += 1
                }
            }
            let shared = try sharedOptions(
                arguments: filtered,
                command: "image cache status",
                allowPositionals: false,
                startIndex: 3
            )
            return ImageCLIOptions(
                action: .cacheStatus(maximumBytes: maximumBytes),
                stateDatabasePath: shared.stateDatabasePath,
                runtimeProvider: shared.runtimeProvider,
                output: shared.output
            )
        case "pin", "unpin":
            let operation = arguments[2]
            let shared = try sharedOptions(
                arguments: arguments,
                command: "image cache \(operation)",
                startIndex: 3
            )
            guard shared.positionals.count == 1 else {
                throw CLIUsageError(
                    "image cache \(operation) requires exactly one managed image reference."
                )
            }
            let reference = try imageValue(
                shared.positionals[0],
                command: "image cache \(operation)"
            )
            return ImageCLIOptions(
                action: operation == "pin"
                    ? .pin(reference: reference)
                    : .unpin(reference: reference),
                stateDatabasePath: shared.stateDatabasePath,
                runtimeProvider: shared.runtimeProvider,
                output: shared.output
            )
        default:
            throw CLIUsageError(
                "image cache supports status, pin, and unpin."
            )
        }
    }

    private struct SharedOptions {
        let stateDatabasePath: String?
        let runtimeProvider: RuntimeProviderSelection
        let output: CLIOutputFormat
        let positionals: [String]
    }

    private static func sharedOptions(
        arguments: [String],
        command: String,
        allowPositionals: Bool = true,
        startIndex: Int = 2
    ) throws -> SharedOptions {
        var stateDatabasePath: String?
        var runtimeProvider: RuntimeProviderSelection = .automatic
        var output: CLIOutputFormat = .text
        var outputSelected = false
        var positionals: [String] = []
        var index = startIndex
        while index < arguments.count {
            switch arguments[index] {
            case "--state-db":
                stateDatabasePath = try uniqueValue(arguments: arguments, index: index, flag: "--state-db", existing: stateDatabasePath, command: command)
                index += 2
            case "--runtime-provider":
                runtimeProvider = try parseRuntimeProvider(arguments: arguments, index: index, existing: runtimeProvider == .automatic ? nil : runtimeProvider, command: command)
                index += 2
            case "--json":
                guard !outputSelected else { throw CLIUsageError("\(command) output may be selected only once.") }
                output = .json
                outputSelected = true
                index += 1
            case "--output":
                guard !outputSelected else { throw CLIUsageError("\(command) output may be selected only once.") }
                output = try parseOutput(arguments: arguments, index: index, command: command)
                outputSelected = true
                index += 2
            case "--all-managed", "--all", "--force":
                throw CLIUsageError("\(command) never permits broad native cleanup selectors.")
            default:
                guard allowPositionals else {
                    throw CLIUsageError("\(command) does not accept positional arguments.")
                }
                positionals.append(arguments[index])
                index += 1
            }
        }
        return SharedOptions(
            stateDatabasePath: stateDatabasePath,
            runtimeProvider: runtimeProvider,
            output: output,
            positionals: positionals
        )
    }

    private static func parseRuntimeProvider(
        arguments: [String],
        index: Int,
        existing: RuntimeProviderSelection?,
        command: String
    ) throws -> RuntimeProviderSelection {
        guard existing == nil else {
            throw CLIUsageError("\(command) accepts --runtime-provider at most once.")
        }
        let value = try requireValue(arguments: arguments, index: index, flag: "--runtime-provider", command: command)
        guard let selection = RuntimeProviderSelection(rawValue: value) else {
            throw CLIUsageError("\(command) --runtime-provider supports only auto, apple-cli, or containerization.")
        }
        return selection
    }

    private static func parseOutput(arguments: [String], index: Int, command: String) throws -> CLIOutputFormat {
        let value = try requireValue(arguments: arguments, index: index, flag: "--output", command: command)
        guard let output = CLIOutputFormat(rawValue: value) else {
            throw CLIUsageError("\(command) --output supports only text or json.")
        }
        return output
    }

    private static func uniqueValue(
        arguments: [String],
        index: Int,
        flag: String,
        existing: String?,
        command: String
    ) throws -> String {
        guard existing == nil else {
            throw CLIUsageError("\(command) accepts \(flag) at most once.")
        }
        return try requireValue(arguments: arguments, index: index, flag: flag, command: command)
    }

    private static func requireValue(
        arguments: [String],
        index: Int,
        flag: String,
        command: String
    ) throws -> String {
        guard index + 1 < arguments.count else {
            throw CLIUsageError("\(command) requires a value after \(flag).")
        }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-") else {
            throw CLIUsageError("\(command) requires a non-empty value after \(flag).")
        }
        return value
    }

    private static func positiveInt64(
        arguments: [String],
        index: Int,
        flag: String,
        command: String
    ) throws -> Int64 {
        let value = try requireValue(
            arguments: arguments,
            index: index,
            flag: flag,
            command: command
        )
        guard let parsed = Int64(value), parsed > 0 else {
            throw CLIUsageError(
                "\(command) \(flag) requires a positive byte count."
            )
        }
        return parsed
    }

    private static func nonnegativeInt64(
        arguments: [String],
        index: Int,
        flag: String,
        command: String
    ) throws -> Int64 {
        let value = try requireValue(
            arguments: arguments,
            index: index,
            flag: flag,
            command: command
        )
        guard let parsed = Int64(value), parsed >= 0 else {
            throw CLIUsageError(
                "\(command) \(flag) requires a nonnegative byte count."
            )
        }
        return parsed
    }

    private static func boundedInt(
        arguments: [String],
        index: Int,
        flag: String,
        command: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        let value = try requireValue(
            arguments: arguments,
            index: index,
            flag: flag,
            command: command
        )
        guard let parsed = Int(value), range.contains(parsed) else {
            throw CLIUsageError(
                "\(command) \(flag) must be between \(range.lowerBound) and \(range.upperBound)."
            )
        }
        return parsed
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil
    }

    private static func imageValue(_ value: String, command: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace),
              (try? RuntimeImageLifecycleContract.validatedReference(trimmed)) != nil else {
            throw CLIUsageError("\(command) requires bounded non-whitespace image values.")
        }
        return trimmed
    }

    private static func normalizedPath(_ value: String, command: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              (try? RuntimeImageLifecycleContract.validatedAbsolutePath(trimmed)) != nil else {
            throw CLIUsageError("\(command) requires a normalized absolute path.")
        }
        return trimmed
    }

    private static func validatePlatform(_ value: String?) throws {
        do {
            _ = try RuntimeImageLifecycleContract.parsedPlatform(value)
        } catch {
            throw CLIUsageError(
                "Image platforms must be exactly linux/arm64 or linux/amd64."
            )
        }
    }
}

import Darwin
import Foundation
import HostwrightCore

public struct ReleaseQualificationCommandLimits: Equatable, Sendable {
    public let timeoutMilliseconds: Int
    public let maximumStandardOutputBytes: Int
    public let maximumStandardErrorBytes: Int

    public init(
        timeoutMilliseconds: Int = 30_000,
        maximumStandardOutputBytes: Int = ReleaseQualificationLimits.maximumOutputBytes,
        maximumStandardErrorBytes: Int = ReleaseQualificationLimits.maximumOutputBytes
    ) throws {
        guard (1...86_400_000).contains(timeoutMilliseconds),
              (1...ReleaseQualificationLimits.maximumOutputBytes)
                  .contains(maximumStandardOutputBytes),
              (1...ReleaseQualificationLimits.maximumOutputBytes)
                  .contains(maximumStandardErrorBytes) else {
            throw ReleaseQualificationContractError.invalid(
                field: "commandLimits",
                reason: "timeout or output limit is outside the bounded range"
            )
        }
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumStandardOutputBytes = maximumStandardOutputBytes
        self.maximumStandardErrorBytes = maximumStandardErrorBytes
    }
}

public struct ReleaseQualificationCommandResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let durationMilliseconds: Int
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool

    public init(
        exitStatus: Int32,
        standardOutput: Data,
        standardError: Data,
        durationMilliseconds: Int,
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false
    ) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.durationMilliseconds = durationMilliseconds
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
    }
}

public enum ReleaseQualificationCommandError: Error, Equatable, Sendable {
    case unavailable
    case timedOut
    case cancelled
    case outputLimitExceeded
    case failed
}

public protocol ReleaseQualificationCommandRunning: Sendable {
    func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult
}

public protocol ReleaseQualificationStandardInputCommandRunning:
    ReleaseQualificationCommandRunning
{
    func run(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult
}

public extension ReleaseQualificationStandardInputCommandRunning {
    func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        try run(
            command,
            standardInput: nil,
            limits: limits,
            cancellation: cancellation
        )
    }
}

public struct ReleaseQualificationSubprocessRunner:
    ReleaseQualificationStandardInputCommandRunning,
    Sendable
{
    public init() {}

    public func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ReleaseQualificationCommandResult {
        try run(
            command,
            standardInput: nil,
            limits: limits,
            cancellation: cancellation
        )
    }

    public func run(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ReleaseQualificationCommandResult {
        try command.validate()
        guard (standardInput?.count ?? 0) <= ReleaseQualificationLimits.maximumSourceFileBytes else {
            throw ReleaseQualificationCommandError.outputLimitExceeded
        }
        let request = SecureSubprocessRequest(
            executablePath: command.executablePath,
            arguments: command.arguments,
            environment: Self.fixedEnvironment,
            workingDirectory: command.workingDirectory,
            standardInput: standardInput,
            timeoutMilliseconds: limits.timeoutMilliseconds,
            maximumStandardOutputBytes: limits.maximumStandardOutputBytes,
            maximumStandardErrorBytes: limits.maximumStandardErrorBytes,
            maximumStandardInputBytes: standardInput.map { max(1, $0.count) }
                ?? SecureSubprocessRequest.defaultMaximumInputBytes
        )
        do {
            let result = try SecureSubprocessRunner().run(
                request,
                cancellation: cancellation
            )
            return ReleaseQualificationCommandResult(
                exitStatus: result.exitStatus,
                standardOutput: result.standardOutput,
                standardError: result.standardError,
                durationMilliseconds: result.durationMilliseconds,
                standardOutputTruncated: result.standardOutputTruncated,
                standardErrorTruncated: result.standardErrorTruncated
            )
        } catch let error as SecureSubprocessError {
            switch error {
            case .timedOut:
                throw ReleaseQualificationCommandError.timedOut
            case .cancelled:
                throw ReleaseQualificationCommandError.cancelled
            case .outputLimitExceeded:
                throw ReleaseQualificationCommandError.outputLimitExceeded
            case .executableRejected,
                 .workingDirectoryRejected,
                 .invalidRequest,
                 .spawnSetupFailed,
                 .launchFailed,
                 .executableChanged:
                throw ReleaseQualificationCommandError.unavailable
            case .inputWriteFailed,
                 .outputReadFailed,
                 .waitFailed,
                 .descendantProcessDetected,
                 .processTreeCleanupFailed:
                throw ReleaseQualificationCommandError.failed
            }
        }
    }

    static let fixedEnvironment: [String: String] = {
        var environment = SecureSubprocessEnvironment.minimal
        environment["GIT_NO_LAZY_FETCH"] = "1"
        return environment
    }()
}

public protocol ReleaseQualificationExecutableLocating: Sendable {
    func path(for tool: ReleaseQualificationTool) -> String?
}

public struct ReleaseQualificationExecutableLocator: ReleaseQualificationExecutableLocating, Sendable {
    public static let trustedSearchPath =
        "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

    public init() {}

    public func path(for tool: ReleaseQualificationTool) -> String? {
        guard let name = Self.name(for: tool) else { return nil }
        do {
            return try SecureExecutableResolver.resolve(
                named: name,
                searchPath: Self.trustedSearchPath,
                ownershipPolicy: .rootOnly
            )?.path
        } catch {
            return nil
        }
    }

    private static func name(for tool: ReleaseQualificationTool) -> String? {
        switch tool {
        case .git: "git"
        case .swVers: "sw_vers"
        case .uname: "uname"
        case .sysctl: "sysctl"
        case .swift: "swift"
        case .swiftc: "swiftc"
        case .appleContainer: "container"
        case .xcodebuild: "xcodebuild"
        case .kubectl: "kubectl"
        case .docker: "docker"
        case .podman: "podman"
        case .brew: "brew"
        case .clang: "clang"
        case .codesign: "codesign"
        case .notarytool: nil
        case .spctl: "spctl"
        case .security: "security"
        case .semgrep: "semgrep"
        case .swiftlint: "swiftlint"
        case .licenseScanner: nil
        case .containerizationFramework: nil
        }
    }
}

public struct ReleaseQualificationEnvironmentDetector: Sendable {
    private let commandRunner: any ReleaseQualificationCommandRunning
    private let executableLocator: any ReleaseQualificationExecutableLocating
    private let defaultLimits: ReleaseQualificationCommandLimits

    public init(
        commandRunner: any ReleaseQualificationCommandRunning = ReleaseQualificationSubprocessRunner(),
        executableLocator: any ReleaseQualificationExecutableLocating =
            ReleaseQualificationExecutableLocator(),
        defaultLimits: ReleaseQualificationCommandLimits = try! ReleaseQualificationCommandLimits()
    ) {
        self.commandRunner = commandRunner
        self.executableLocator = executableLocator
        self.defaultLimits = defaultLimits
    }

    public func detect(
        sourceRoot: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ReleaseQualificationDetectedEnvironment {
        try validateSourceRoot(sourceRoot)
        try checkCancellation(cancellation)

        var commandObservations: [ReleaseQualificationCommandObservation] = []
        let source = detectSource(
            sourceRoot: sourceRoot,
            observations: &commandObservations,
            cancellation: cancellation
        )
        let phase08Release = detectPhase08Release(
            sourceRoot: sourceRoot,
            observations: &commandObservations,
            cancellation: cancellation
        )
        let host = detectHost(
            observations: &commandObservations,
            cancellation: cancellation
        )
        var tools = detectProcessTools(
            sourceRoot: sourceRoot,
            observations: &commandObservations,
            cancellation: cancellation
        )
        tools.append(detectContainerizationFramework(sourceRoot: sourceRoot))

        let environment = ReleaseQualificationDetectedEnvironment(
            source: source,
            phase08Release: phase08Release,
            host: host,
            tools: tools,
            commands: commandObservations
        )
        try environment.validate()
        return environment
    }

    func detectSourceState(
        sourceRoot: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> (
        source: ReleaseQualificationSourceFacts,
        commands: [ReleaseQualificationCommandObservation]
    ) {
        try validateSourceRoot(sourceRoot)
        try checkCancellation(cancellation)
        var observations: [ReleaseQualificationCommandObservation] = []
        let source = detectSource(
            sourceRoot: sourceRoot,
            observations: &observations,
            cancellation: cancellation
        )
        try source.validate()
        return (source, observations)
    }

    private func detectSource(
        sourceRoot: URL,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) -> ReleaseQualificationSourceFacts {
        guard let executablePath = executableLocator.path(for: .git) else {
            return ReleaseQualificationSourceFacts(
                availability: .init(status: .unavailable, reason: .missingTool),
                commit: nil,
                dirty: nil,
                dirtyStateSHA256: nil
            )
        }
        do {
            let head = try execute(
                executablePath: executablePath,
                arguments: [
                    "-C", sourceRoot.path, "rev-parse", "--verify", "HEAD^{commit}"
                ],
                purpose: "read source commit",
                workingDirectory: sourceRoot.path,
                observations: &observations,
                cancellation: cancellation
            )
            let status = try execute(
                executablePath: executablePath,
                arguments: [
                    "-C", sourceRoot.path, "status", "--porcelain=v1",
                    "--untracked-files=all", "-z"
                ],
                purpose: "read source dirty state",
                workingDirectory: sourceRoot.path,
                observations: &observations,
                cancellation: cancellation
            )
            let diff = try execute(
                executablePath: executablePath,
                arguments: [
                    "-C", sourceRoot.path, "diff", "--no-ext-diff", "--binary", "HEAD", "--"
                ],
                purpose: "hash tracked source changes",
                workingDirectory: sourceRoot.path,
                observations: &observations,
                cancellation: cancellation
            )
            let untracked = try execute(
                executablePath: executablePath,
                arguments: [
                    "-C", sourceRoot.path, "ls-files", "--others", "--exclude-standard", "-z"
                ],
                purpose: "enumerate untracked source files",
                workingDirectory: sourceRoot.path,
                observations: &observations,
                cancellation: cancellation
            )
            guard let headString = decodeSingleLine(head.output),
                  let commit = try? ReleaseQualificationCommit(headString) else {
                return ReleaseQualificationSourceFacts(
                    availability: .init(status: .malformed, reason: .malformedFact),
                    commit: nil,
                    dirty: nil,
                    dirtyStateSHA256: nil
                )
            }
            let digest = try dirtyStateDigest(
                status: status.rawOutput,
                diff: diff.rawOutput,
                untracked: untracked.rawOutput,
                sourceRoot: sourceRoot
            )
            return ReleaseQualificationSourceFacts(
                availability: .init(status: .available),
                commit: commit,
                dirty: !status.rawOutput.isEmpty ||
                    !diff.rawOutput.isEmpty ||
                    !untracked.rawOutput.isEmpty,
                dirtyStateSHA256: digest
            )
        } catch let error as ReleaseQualificationCommandError {
            return ReleaseQualificationSourceFacts(
                availability: .init(
                    status: error == .outputLimitExceeded ? .malformed : .unavailable,
                    reason: error == .outputLimitExceeded
                        ? .outputLimitExceeded
                        : error == .cancelled ? .cancellation : .unavailableFact
                ),
                commit: nil,
                dirty: nil,
                dirtyStateSHA256: nil
            )
        } catch {
            return ReleaseQualificationSourceFacts(
                availability: .init(status: .malformed, reason: .malformedFact),
                commit: nil,
                dirty: nil,
                dirtyStateSHA256: nil
            )
        }
    }

    private func detectPhase08Release(
        sourceRoot: URL,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) -> ReleaseQualificationPhase08ReleaseFacts {
        guard let executablePath = executableLocator.path(for: .git) else {
            return ReleaseQualificationPhase08ReleaseFacts(
                availability: .init(status: .unavailable, reason: .missingTool),
                releaseCommit: nil,
                sourceContainsRelease: nil
            )
        }
        do {
            let expectedCommit = ReleaseQualificationLimits.phase08ReleaseCommit
            let releaseObject = try execute(
                executablePath: executablePath,
                arguments: [
                    "-C", sourceRoot.path, "rev-parse", "--verify", "\(expectedCommit)^{commit}"
                ],
                purpose: "verify released Phase 08 main commit",
                workingDirectory: sourceRoot.path,
                observations: &observations,
                cancellation: cancellation
            )
            guard releaseObject.output == expectedCommit,
                  let releaseCommit = try? ReleaseQualificationCommit(expectedCommit) else {
                return ReleaseQualificationPhase08ReleaseFacts(
                    availability: .init(status: .malformed, reason: .malformedFact),
                    releaseCommit: nil,
                    sourceContainsRelease: nil
                )
            }
            let ancestryStatus = try executeStatus(
                executablePath: executablePath,
                arguments: [
                    "-C", sourceRoot.path, "merge-base", "--is-ancestor", expectedCommit, "HEAD"
                ],
                purpose: "verify Phase 08 release ancestry",
                workingDirectory: sourceRoot.path,
                observations: &observations,
                cancellation: cancellation
            )
            guard ancestryStatus == 0 || ancestryStatus == 1 else {
                return ReleaseQualificationPhase08ReleaseFacts(
                    availability: .init(status: .unavailable, reason: .unavailableFact),
                    releaseCommit: nil,
                    sourceContainsRelease: nil
                )
            }
            return ReleaseQualificationPhase08ReleaseFacts(
                availability: .init(status: .available),
                releaseCommit: releaseCommit,
                sourceContainsRelease: ancestryStatus == 0
            )
        } catch let error as ReleaseQualificationCommandError {
            return ReleaseQualificationPhase08ReleaseFacts(
                availability: .init(
                    status: error == .outputLimitExceeded ? .malformed : .unavailable,
                    reason: error == .outputLimitExceeded
                        ? .outputLimitExceeded
                        : error == .cancelled ? .cancellation : .unavailableFact
                ),
                releaseCommit: nil,
                sourceContainsRelease: nil
            )
        } catch {
            return ReleaseQualificationPhase08ReleaseFacts(
                availability: .init(status: .malformed, reason: .malformedFact),
                releaseCommit: nil,
                sourceContainsRelease: nil
            )
        }
    }

    private func detectHost(
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) -> ReleaseQualificationHostFacts {
        let required: [(ReleaseQualificationTool, [String], String)] = [
            (.swVers, ["-productVersion"], "read macOS product version"),
            (.swVers, ["-buildVersion"], "read macOS build"),
            (.uname, ["-m"], "read host architecture"),
            (.sysctl, ["-n", "hw.model"], "read hardware model"),
            (.sysctl, ["-n", "hw.memsize"], "read memory size"),
            (.sysctl, ["-n", "hw.optional.arm64"], "read Apple silicon capability")
        ]
        var outputs: [String] = []
        for (tool, arguments, purpose) in required {
            guard let path = executableLocator.path(for: tool) else {
                return unavailableHost(.missingTool)
            }
            do {
                let result = try execute(
                    executablePath: path,
                    arguments: arguments,
                    purpose: purpose,
                    workingDirectory: "/",
                    observations: &observations,
                    cancellation: cancellation
                )
                outputs.append(result.output)
            } catch let error as ReleaseQualificationCommandError {
                return unavailableHost(
                    error == .outputLimitExceeded ? .outputLimitExceeded :
                        error == .cancelled ? .cancellation : .unavailableFact,
                    status: error == .outputLimitExceeded ? .malformed : .unavailable
                )
            } catch {
                return unavailableHost(.malformedFact, status: .malformed)
            }
        }

        guard let macOSVersion = try? ReleaseQualificationSemanticVersion(
            parsing: outputs[0],
            allowingTwoComponents: true
        ),
        let build = validatedFactString(outputs[1], maximumBytes: 128),
        let architecture = parseArchitecture(outputs[2]),
        let hardwareModel = validatedFactString(outputs[3], maximumBytes: 256),
        let memoryBytes = Int64(outputs[4]),
        memoryBytes > 0,
        let arm64Capability = parseBoolean(outputs[5]) else {
            return unavailableHost(.malformedFact, status: .malformed)
        }
        return ReleaseQualificationHostFacts(
            availability: .init(status: .available),
            macOSVersion: macOSVersion,
            build: build,
            architecture: architecture,
            hardwareModel: hardwareModel,
            memoryBytes: memoryBytes,
            arm64Capability: arm64Capability
        )
    }

    private func detectProcessTools(
        sourceRoot: URL,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) -> [ReleaseQualificationToolFact] {
        let tools: [ReleaseQualificationTool] = [
            .swift, .swiftc, .appleContainer, .xcodebuild, .kubectl, .docker,
            .podman, .brew, .clang, .codesign, .security, .semgrep, .swiftlint
        ]
        return tools.map { tool in
            detectProcessTool(
                tool: tool,
                sourceRoot: sourceRoot,
                observations: &observations,
                cancellation: cancellation
            )
        }
    }

    private func detectProcessTool(
        tool: ReleaseQualificationTool,
        sourceRoot: URL,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) -> ReleaseQualificationToolFact {
        guard let executablePath = executableLocator.path(for: tool) else {
            return ReleaseQualificationToolFact(
                tool: tool,
                origin: .process,
                availability: .init(status: .unavailable, reason: .missingTool),
                executablePath: nil,
                version: nil,
                rawOutputSHA256: nil,
                command: nil
            )
        }
        let arguments: [String] = switch tool {
        case .swift, .swiftc: ["--version"]
        case .appleContainer: ["--version"]
        case .xcodebuild: ["-version"]
        case .kubectl: ["version", "--client=true", "--output=json"]
        case .docker: ["--version"]
        case .podman: ["--version"]
        case .brew: ["--version"]
        case .clang: ["--version"]
        case .codesign: ["--version"]
        case .security: ["-h"]
        case .semgrep: ["--version"]
        case .swiftlint: ["version"]
        default: []
        }
        guard let command = try? ReleaseQualificationCommandIdentity(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: sourceRoot.path,
            purpose: "read \(tool.rawValue) version"
        ) else {
            return ReleaseQualificationToolFact(
                tool: tool,
                origin: .process,
                availability: .init(status: .malformed, reason: .malformedFact),
                executablePath: executablePath,
                version: nil,
                rawOutputSHA256: nil,
                command: nil
            )
        }
        do {
            let result = try execute(
                command: command,
                observations: &observations,
                cancellation: cancellation
            )
            guard let version = parseToolVersion(tool: tool, output: result.output) else {
                return ReleaseQualificationToolFact(
                    tool: tool,
                    origin: .process,
                    availability: .init(status: .malformed, reason: .malformedFact),
                    executablePath: executablePath,
                    version: nil,
                    rawOutputSHA256: ReleaseQualificationHash.sha256(
                        data: result.rawOutput
                    ),
                    command: command
                )
            }
            return ReleaseQualificationToolFact(
                tool: tool,
                origin: .process,
                availability: .init(status: .available),
                executablePath: executablePath,
                version: version,
                rawOutputSHA256: ReleaseQualificationHash.sha256(data: result.rawOutput),
                command: command
            )
        } catch let error as ReleaseQualificationCommandError {
            return ReleaseQualificationToolFact(
                tool: tool,
                origin: .process,
                availability: .init(
                    status: error == .outputLimitExceeded ? .malformed : .unavailable,
                    reason: error == .outputLimitExceeded ? .outputLimitExceeded :
                        error == .cancelled ? .cancellation : .unavailableFact
                ),
                executablePath: executablePath,
                version: nil,
                rawOutputSHA256: nil,
                command: command
            )
        } catch {
            return ReleaseQualificationToolFact(
                tool: tool,
                origin: .process,
                availability: .init(status: .malformed, reason: .malformedFact),
                executablePath: executablePath,
                version: nil,
                rawOutputSHA256: nil,
                command: command
            )
        }
    }

    private func detectContainerizationFramework(sourceRoot: URL) -> ReleaseQualificationToolFact {
        let package = sourceRoot.appendingPathComponent("Package.swift")
        let resolved = sourceRoot.appendingPathComponent("Package.resolved")
        do {
            guard try ReleaseQualificationFile.isRegularNonSymlink(package),
                  try ReleaseQualificationFile.isRegularNonSymlink(resolved) else {
                return unavailableFramework(.dependencyUnavailable)
            }
            let packageData = try Data(contentsOf: package, options: .mappedIfSafe)
            let resolvedData = try Data(contentsOf: resolved, options: .mappedIfSafe)
            guard packageData.count <= ReleaseQualificationLimits.maximumSourceFileBytes,
                  resolvedData.count <= ReleaseQualificationLimits.maximumSourceFileBytes,
                  let packageText = String(data: packageData, encoding: .utf8),
                  let manifestVersion = parseExactContainerizationVersion(packageText),
                  let resolvedVersion = parseResolvedContainerizationVersion(resolvedData) else {
                return unavailableFramework(.malformedFact, status: .malformed)
            }
            guard manifestVersion == resolvedVersion else {
                return unavailableFramework(.mixedVersions, status: .malformed)
            }
            return ReleaseQualificationToolFact(
                tool: .containerizationFramework,
                origin: .packageResolved,
                availability: .init(status: .available),
                executablePath: nil,
                version: manifestVersion,
                rawOutputSHA256: ReleaseQualificationHash.sha256(
                    data: packageData + resolvedData
                ),
                command: nil
            )
        } catch {
            return unavailableFramework(.unavailableFact)
        }
    }

    private func execute(
        executablePath: String,
        arguments: [String],
        purpose: String,
        workingDirectory: String,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) throws -> ExecutedOutput {
        let command = try ReleaseQualificationCommandIdentity(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            purpose: purpose
        )
        return try execute(
            command: command,
            observations: &observations,
            cancellation: cancellation
        )
    }

    private func execute(
        command: ReleaseQualificationCommandIdentity,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) throws -> ExecutedOutput {
        try checkCancellation(cancellation)
        let started = ReleaseQualificationTimestamp()
        let result = try commandRunner.run(
            command,
            limits: defaultLimits,
            cancellation: cancellation
        )
        let ended = ReleaseQualificationTimestamp()
        let observation = ReleaseQualificationCommandObservation(
            identity: command,
            startedAt: started,
            endedAt: ended,
            durationMilliseconds: result.durationMilliseconds,
            exitStatus: result.exitStatus,
            standardOutputSHA256: ReleaseQualificationHash.sha256(data: result.standardOutput),
            standardErrorSHA256: ReleaseQualificationHash.sha256(data: result.standardError),
            standardOutputBytes: result.standardOutput.count,
            standardErrorBytes: result.standardError.count,
            standardOutputTruncated: result.standardOutputTruncated,
            standardErrorTruncated: result.standardErrorTruncated
        )
        observations.append(observation)
        guard result.exitStatus == 0 else { throw ReleaseQualificationCommandError.failed }
        guard !result.standardOutputTruncated, !result.standardErrorTruncated else {
            throw ReleaseQualificationCommandError.outputLimitExceeded
        }
        guard let output = String(data: result.standardOutput, encoding: .utf8) else {
            throw ReleaseQualificationCommandError.failed
        }
        return ExecutedOutput(
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            rawOutput: result.standardOutput + result.standardError
        )
    }

    private func executeStatus(
        executablePath: String,
        arguments: [String],
        purpose: String,
        workingDirectory: String,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) throws -> Int32 {
        let command = try ReleaseQualificationCommandIdentity(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            purpose: purpose
        )
        try checkCancellation(cancellation)
        let started = ReleaseQualificationTimestamp()
        let result = try commandRunner.run(
            command,
            limits: defaultLimits,
            cancellation: cancellation
        )
        let ended = ReleaseQualificationTimestamp()
        observations.append(
            ReleaseQualificationCommandObservation(
                identity: command,
                startedAt: started,
                endedAt: ended,
                durationMilliseconds: result.durationMilliseconds,
                exitStatus: result.exitStatus,
                standardOutputSHA256: ReleaseQualificationHash.sha256(data: result.standardOutput),
                standardErrorSHA256: ReleaseQualificationHash.sha256(data: result.standardError),
                standardOutputBytes: result.standardOutput.count,
                standardErrorBytes: result.standardError.count,
                standardOutputTruncated: result.standardOutputTruncated,
                standardErrorTruncated: result.standardErrorTruncated
            )
        )
        guard !result.standardOutputTruncated, !result.standardErrorTruncated else {
            throw ReleaseQualificationCommandError.outputLimitExceeded
        }
        return result.exitStatus
    }

    private func dirtyStateDigest(
        status: Data,
        diff: Data,
        untracked: Data,
        sourceRoot: URL
    ) throws -> ReleaseQualificationSHA256 {
        var data = Data()
        data.append(status)
        data.append(Data([0]))
        data.append(diff)
        data.append(Data([0]))
        data.append(untracked)
        data.append(Data([0]))
        let paths = untracked
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
            .sorted()
        var total = data.count
        for path in paths {
            guard ReleaseQualificationPath.isSafeRelative(path) else {
                throw ReleaseQualificationContractError.unsafePath
            }
            let url = sourceRoot.appendingPathComponent(path)
            guard ReleaseQualificationPath.isContained(url, in: sourceRoot) else {
                throw ReleaseQualificationContractError.unsafePath
            }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw ReleaseQualificationContractError.unsafePath
            }
            data.append(Data(path.utf8))
            data.append(Data([0]))
            if metadata.st_mode & S_IFMT == S_IFLNK {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                let length = readlink(url.path, &buffer, buffer.count)
                guard length >= 0 else { throw ReleaseQualificationContractError.unsafePath }
                data.append(Data(bytes: buffer, count: Int(length)))
            } else {
                guard metadata.st_mode & S_IFMT == S_IFREG else {
                    throw ReleaseQualificationContractError.unsafePath
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let size = (attributes[.size] as? NSNumber)?.intValue,
                      size >= 0,
                      size <= ReleaseQualificationLimits.maximumSourceFileBytes else {
                    throw ReleaseQualificationContractError.oversizedInput
                }
                let contents = try Data(contentsOf: url, options: .mappedIfSafe)
                total += contents.count
                guard total <= ReleaseQualificationLimits.maximumSourceScanBytes else {
                    throw ReleaseQualificationContractError.oversizedInput
                }
                data.append(contents)
            }
            data.append(Data([0]))
        }
        return ReleaseQualificationHash.sha256(data: data)
    }

    private func validateSourceRoot(_ root: URL) throws {
        guard ReleaseQualificationPath.isNormalizedAbsolute(root.path),
              try ReleaseQualificationFile.isDirectory(root) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == root.path else {
            throw ReleaseQualificationContractError.unsafePath
        }
    }

    private func checkCancellation(_ cancellation: SecureSubprocessCancellation) throws {
        guard !cancellation.isCancelled else {
            throw ReleaseQualificationCommandError.cancelled
        }
    }

    private func decodeSingleLine(_ output: String) -> String? {
        let values = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard values.count == 1 else { return nil }
        let value = String(values[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func validatedFactString(_ output: String, maximumBytes: Int) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return value
    }

    private func parseArchitecture(_ value: String) -> ReleaseQualificationArchitecture? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "arm64": .arm64
        case "x86_64": .x86_64
        default: .unknown
        }
    }

    private func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1", "true": true
        case "0", "false": false
        default: nil
        }
    }

    private func parseToolVersion(
        tool: ReleaseQualificationTool,
        output: String
    ) -> ReleaseQualificationSemanticVersion? {
        let preferredPattern: String? = switch tool {
        case .swift, .swiftc:
            "Apple Swift version ([0-9]+\\.[0-9]+(?:\\.[0-9]+)?)"
        case .xcodebuild:
            "Xcode ([0-9]+\\.[0-9]+(?:\\.[0-9]+)?)"
        default:
            nil
        }
        if let preferredPattern,
           let preferred = firstCapture(preferredPattern, in: output),
           let version = try? ReleaseQualificationSemanticVersion(
               parsing: preferred,
               allowingTwoComponents: true
           ) {
            return version
        }
        guard let value = firstMatch(
            "[0-9]+\\.[0-9]+(?:\\.[0-9]+)?",
            in: output
        ) else { return nil }
        return try? ReleaseQualificationSemanticVersion(
            parsing: value,
            allowingTwoComponents: true
        )
    }

    private func firstCapture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range])
    }

    private func firstMatch(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range, in: value) else {
            return nil
        }
        return String(value[range])
    }

    private func parseExactContainerizationVersion(
        _ packageText: String
    ) -> ReleaseQualificationSemanticVersion? {
        guard let value = firstCapture(
            #"url\s*:\s*"https://github\.com/apple/containerization\.git"\s*,\s*exact\s*:\s*"([^"]+)""#,
            in: packageText
        ) else { return nil }
        return try? ReleaseQualificationSemanticVersion(parsing: value)
    }

    private func parseResolvedContainerizationVersion(
        _ data: Data
    ) -> ReleaseQualificationSemanticVersion? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = object["pins"] as? [[String: Any]] else { return nil }
        for pin in pins where pin["identity"] as? String == "containerization" {
            guard let state = pin["state"] as? [String: Any],
                  let version = state["version"] as? String else { return nil }
            return try? ReleaseQualificationSemanticVersion(parsing: version)
        }
        return nil
    }

    private func unavailableHost(
        _ reason: ReleaseQualificationUnsupportedReason,
        status: ReleaseQualificationFactStatus = .unavailable
    ) -> ReleaseQualificationHostFacts {
        ReleaseQualificationHostFacts(
            availability: .init(status: status, reason: reason),
            macOSVersion: nil,
            build: nil,
            architecture: nil,
            hardwareModel: nil,
            memoryBytes: nil,
            arm64Capability: nil
        )
    }

    private func unavailableFramework(
        _ reason: ReleaseQualificationUnsupportedReason,
        status: ReleaseQualificationFactStatus = .unavailable
    ) -> ReleaseQualificationToolFact {
        ReleaseQualificationToolFact(
            tool: .containerizationFramework,
            origin: .packageResolved,
            availability: .init(status: status, reason: reason),
            executablePath: nil,
            version: nil,
            rawOutputSHA256: nil,
            command: nil
        )
    }

    private struct ExecutedOutput: Sendable {
        let output: String
        let rawOutput: Data
    }
}

public struct ReleaseQualificationEnvironmentEvaluator: Sendable {
    public init() {}

    public func evaluate(
        cell: ReleaseQualificationMatrixCell,
        environment: ReleaseQualificationDetectedEnvironment
    ) -> ReleaseQualificationEvaluation {
        var blockers: [ReleaseQualificationBlocker] = []
        let sourceStatus = environment.source.availability.status
        if sourceStatus != .available {
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: environment.source.availability.reason ?? .unknownFact,
                    field: "source",
                    detail: "source commit and dirty-state identity are not available"
                )
            )
        } else if environment.source.dirty == true {
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: .dirtySource,
                    field: "source.dirty",
                    detail: "release evidence requires an exact clean source tree"
                )
            )
        }

        if cell.authority == .phase08Runtime {
            let releaseIsAvailable = environment.phase08Release.map {
                $0.availability.status == .available && $0.sourceContainsRelease == true
            } == true
            if !releaseIsAvailable {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .phase08ReleaseUnavailable,
                        field: "environment.phase08Release",
                        detail: "the source tree does not contain the released Phase 08 main checkpoint"
                    )
                )
            }
        }

        if environment.host.availability.status != .available {
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: environment.host.availability.reason ?? .unknownFact,
                    field: "host",
                    detail: "required macOS and hardware facts are unavailable"
                )
            )
        } else {
            guard let macOS = environment.host.macOSVersion,
                  let architecture = environment.host.architecture,
                  let model = environment.host.hardwareModel,
                  let arm64Capability = environment.host.arm64Capability else {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .malformedFact,
                        field: "host",
                        detail: "host facts are incomplete"
                    )
                )
                return makeEvaluation(cellID: cell.id, blockers: blockers)
            }
            if macOS.major > cell.macOSMajor {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .futureVersion,
                        field: "host.macOSVersion",
                        detail: "detected macOS major is newer than the committed cell"
                    )
                )
            } else if macOS.major != cell.macOSMajor {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .unsupportedMacOSVersion,
                        field: "host.macOSVersion",
                        detail: "detected macOS major is outside the committed matrix"
                    )
                )
            }
            if architecture != cell.architecture || !arm64Capability {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .unsupportedArchitecture,
                        field: "host.architecture",
                        detail: "detected architecture is not the committed arm64 cell"
                    )
                )
            }
            if cell.hardware == .appleSilicon,
               architecture == .arm64,
               arm64Capability,
               !model.hasPrefix("Mac") {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .unsupportedHardware,
                        field: "host.hardwareModel",
                        detail: "hardware identity is not a physical Apple silicon Mac model"
                    )
                )
            }
        }

        for tool in cell.requiredTools {
            guard let fact = environment.tool(tool) else {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .missingTool,
                        field: "tools.\(tool.rawValue)",
                        detail: "required committed matrix fact was not detected"
                    )
                )
                continue
            }
            guard fact.availability.status == .available else {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: fact.availability.reason ?? .unknownFact,
                        field: "tools.\(tool.rawValue)",
                        detail: "required tool or framework version is unavailable"
                    )
                )
                continue
            }
            let expected = cell.provider == .appleContainerCLI
                ? cell.runtimeVersion
                : cell.frameworkVersion
            guard let expected, let observed = fact.version else {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .malformedFact,
                        field: "tools.\(tool.rawValue).version",
                        detail: "required version fact is incomplete"
                    )
                )
                continue
            }
            if observed > expected {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .futureVersion,
                        field: "tools.\(tool.rawValue).version",
                        detail: "detected version is newer than the committed cell"
                    )
                )
            } else if observed != expected {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .unsupportedVersion,
                        field: "tools.\(tool.rawValue).version",
                        detail: "detected version does not match the committed cell"
                    )
                )
            }
        }
        return makeEvaluation(cellID: cell.id, blockers: blockers)
    }

    private func makeEvaluation(
        cellID: String,
        blockers: [ReleaseQualificationBlocker]
    ) -> ReleaseQualificationEvaluation {
        let unique = Dictionary(grouping: blockers, by: { "\($0.reason.rawValue):\($0.field)" })
            .compactMap { $0.value.first }
            .sorted { ($0.reason.rawValue, $0.field) < ($1.reason.rawValue, $1.field) }
        let dirty = unique.contains { $0.reason == .dirtySource }
        let unavailable = unique.contains {
            [.missingTool, .unavailableFact, .sourceCommitUnavailable, .dependencyUnavailable]
                .contains($0.reason)
        }
        let status: ReleaseQualificationOutcomeStatus = if unique.isEmpty {
            .passed
        } else if dirty {
            .dirty
        } else if unavailable {
            .unavailable
        } else {
            .blocked
        }
        return ReleaseQualificationEvaluation(
            cellID: cellID,
            status: status,
            blockers: unique,
            matched: unique.isEmpty
        )
    }
}

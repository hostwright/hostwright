import Foundation
import HostwrightScheduler

#if canImport(Darwin)
import Darwin
#endif

enum Phase10SchedulerQualification {
    static let defaultSeed: UInt64 = 0x10_209_214

    struct Configuration {
        static let generatedCountEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_GENERATED_COUNT"
        static let exactCountEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_EXACT_COUNT"
        static let seedEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_SEED"
        static let performanceEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_PERFORMANCE"
        static let performanceRepeatsEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_PERFORMANCE_REPEATS"
        static let referenceMacEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_REFERENCE_MAC"
        static let referenceMacIDEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_REFERENCE_MAC_ID"
        static let outputRootEnvironment = "HOSTWRIGHT_PHASE10_SCHEDULER_QUAL_OUTPUT_ROOT"

        let seed: UInt64
        let generatedCount: Int
        let exactCount: Int
        let performanceEnabled: Bool
        let performanceRepeats: Int
        let referenceMacGateEnabled: Bool
        let referenceMacID: String?
        let explicitOutputRoot: URL?

        init(
            seed: UInt64 = Phase10SchedulerQualification.defaultSeed,
            generatedCount: Int = 48,
            exactCount: Int = 24,
            performanceEnabled: Bool = false,
            performanceRepeats: Int = 7,
            referenceMacGateEnabled: Bool = false,
            referenceMacID: String? = nil,
            explicitOutputRoot: URL? = nil
        ) throws {
            guard generatedCount > 0, generatedCount <= 1_000_000 else {
                throw ConfigurationError.invalidCount(
                    name: Self.generatedCountEnvironment,
                    value: generatedCount,
                    maximum: 1_000_000
                )
            }
            guard exactCount > 0, exactCount <= 10_000 else {
                throw ConfigurationError.invalidCount(
                    name: Self.exactCountEnvironment,
                    value: exactCount,
                    maximum: 10_000
                )
            }
            guard performanceRepeats >= 5, performanceRepeats <= 1_000 else {
                throw ConfigurationError.invalidCount(
                    name: Self.performanceRepeatsEnvironment,
                    value: performanceRepeats,
                    maximum: 1_000
                )
            }
            if let explicitOutputRoot {
                try Self.validateExplicitOutputRoot(explicitOutputRoot)
            }
            let normalizedReferenceMacID = referenceMacID?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if referenceMacGateEnabled {
                guard performanceEnabled else {
                    throw ConfigurationError.referenceMacGateRequiresPerformance
                }
                guard explicitOutputRoot != nil else {
                    throw ConfigurationError.referenceMacGateRequiresExplicitOutputRoot
                }
                guard !(normalizedReferenceMacID?.isEmpty ?? true) else {
                    throw ConfigurationError.referenceMacGateRequiresIdentifier
                }
                guard performanceRepeats == 7 else {
                    throw ConfigurationError.referenceMacGateRequiresSevenSamples
                }
            } else {
                guard normalizedReferenceMacID == nil else {
                    throw ConfigurationError.referenceMacGateForbidsIdentifier
                }
            }
            self.seed = seed
            self.generatedCount = generatedCount
            self.exactCount = exactCount
            self.performanceEnabled = performanceEnabled
            self.performanceRepeats = performanceRepeats
            self.referenceMacGateEnabled = referenceMacGateEnabled
            self.referenceMacID = normalizedReferenceMacID
            self.explicitOutputRoot = explicitOutputRoot
        }

        static func current(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) throws -> Configuration {
            let seed = try unsigned(
                environment[seedEnvironment],
                name: seedEnvironment,
                defaultValue: Phase10SchedulerQualification.defaultSeed
            )
            let generatedCount = try count(
                environment[generatedCountEnvironment],
                name: generatedCountEnvironment,
                defaultValue: 48,
                maximum: 1_000_000
            )
            let exactCount = try count(
                environment[exactCountEnvironment],
                name: exactCountEnvironment,
                defaultValue: 24,
                maximum: 10_000
            )
            let performanceRepeats = try count(
                environment[performanceRepeatsEnvironment],
                name: performanceRepeatsEnvironment,
                defaultValue: 7,
                maximum: 1_000
            )
            let outputRoot = environment[outputRootEnvironment].flatMap { raw -> URL? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
            }
            return try Configuration(
                seed: seed,
                generatedCount: generatedCount,
                exactCount: exactCount,
                performanceEnabled: enabled(environment[performanceEnvironment]),
                performanceRepeats: performanceRepeats,
                referenceMacGateEnabled: enabled(environment[referenceMacEnvironment]),
                referenceMacID: environment[referenceMacIDEnvironment],
                explicitOutputRoot: outputRoot
            )
        }

        var hasQualifiedReferenceMacGate: Bool {
            referenceMacGateEnabled
        }

        private static func count(
            _ raw: String?,
            name: String,
            defaultValue: Int,
            maximum: Int
        ) throws -> Int {
            guard let raw, !raw.isEmpty else {
                return defaultValue
            }
            guard let value = Int(raw), value > 0, value <= maximum else {
                throw ConfigurationError.invalidEnvironment(name: name, value: raw)
            }
            return value
        }

        private static func unsigned(
            _ raw: String?,
            name: String,
            defaultValue: UInt64
        ) throws -> UInt64 {
            guard let raw, !raw.isEmpty else {
                return defaultValue
            }
            let value: UInt64?
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
                value = UInt64(raw.dropFirst(2), radix: 16)
            } else {
                value = UInt64(raw)
            }
            guard let value else {
                throw ConfigurationError.invalidEnvironment(name: name, value: raw)
            }
            return value
        }

        private static func enabled(_ raw: String?) -> Bool {
            ["1", "true", "yes"].contains(raw?.lowercased())
        }

        static func validateExplicitOutputRoot(_ root: URL) throws {
            let standardizedRoot = root.standardizedFileURL
            guard standardizedRoot.isFileURL,
                  !standardizedRoot.path.isEmpty,
                  standardizedRoot.path != "/" else {
                throw ConfigurationError.disallowedOutputRoot(root.path)
            }
            guard FileManager.default.fileExists(atPath: standardizedRoot.path),
                  !hasSymlinkComponent(standardizedRoot),
                  let resolvedRoot = resolvedRealPath(standardizedRoot) else {
                throw ConfigurationError.disallowedOutputRoot(root.path)
            }
            if standardizedRoot.path == ownedDurableOutputRoot.standardizedFileURL.path {
                guard resolvedRoot == resolvedRealPath(ownedDurableOutputRoot.standardizedFileURL) else {
                    throw ConfigurationError.disallowedOutputRoot(root.path)
                }
                try validateExistingOrNearestParent(
                    standardizedRoot,
                    requirePrivateExistingDirectory: true
                )
                return
            }
            let pathComponents = standardizedRoot.pathComponents.map { $0.lowercased() }
            guard !pathComponents.contains("evidence"),
                  !pathComponents.contains(where: { $0.contains("phase08") || $0.contains("phase09") }) else {
                throw ConfigurationError.disallowedOutputRoot(root.path)
            }
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
            let isTemporaryRoot = isWithin(standardizedRoot, root: temporaryRoot)
            guard isTemporaryRoot,
                  let resolvedTemporaryRoot = resolvedRealPath(temporaryRoot),
                  resolvedRoot == resolvedTemporaryRoot || resolvedRoot.hasPrefix(resolvedTemporaryRoot + "/") else {
                throw ConfigurationError.disallowedOutputRoot(root.path)
            }
            try validateExistingOrNearestParent(
                standardizedRoot,
                requirePrivateExistingDirectory: true
            )
        }

        static func isWithin(_ child: URL, root: URL) -> Bool {
            let childPath = child.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            guard childPath != rootPath else { return true }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return childPath.hasPrefix(prefix)
        }

        static func hasSymlinkComponent(_ url: URL) -> Bool {
            var current = URL(fileURLWithPath: "/", isDirectory: true)
            for component in url.standardizedFileURL.pathComponents {
                if component == "/" { continue }
                current.appendPathComponent(component, isDirectory: true)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
                      let type = attributes[.type] as? FileAttributeType else {
                    continue
                }
                if type == .typeSymbolicLink {
                    // Only the documented macOS compatibility links are
                    // accepted, and only when they resolve to their exact
                    // system targets.  Caller-owned links are rejected.
                    let resolved = try? FileManager.default.destinationOfSymbolicLink(
                        atPath: current.path
                    )
                    if (current.path == "/var" && resolved == "private/var")
                        || (current.path == "/tmp" && resolved == "private/tmp") {
                        continue
                    }
                    return true
                }
            }
            return false
        }

        static func resolvedRealPath(_ url: URL) -> String? {
#if canImport(Darwin)
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard Darwin.realpath(url.path, &buffer) != nil else { return nil }
            return String(cString: buffer)
#else
            return url.resolvingSymlinksInPath().standardizedFileURL.path
#endif
        }

        private static func validateExistingOrNearestParent(
            _ url: URL,
            requirePrivateExistingDirectory: Bool
        ) throws {
            let current = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: current.path) else {
                throw ConfigurationError.disallowedOutputRoot(url.path)
            }
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
            let boundary = isWithin(current, root: temporaryRoot) ? temporaryRoot : current
            var ancestor = current
            while true {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
                      (attributes[.type] as? FileAttributeType) == .typeDirectory,
                      let owner = attributes[.ownerAccountName] as? String,
                      owner == NSUserName(),
                      let permissions = attributes[.posixPermissions] as? NSNumber,
                      (!requirePrivateExistingDirectory || permissions.intValue & 0o077 == 0) else {
                    throw ConfigurationError.disallowedOutputRoot(url.path)
                }
                if ancestor.path == boundary.path { break }
                let parent = ancestor.deletingLastPathComponent()
                guard parent.path != ancestor.path else {
                    throw ConfigurationError.disallowedOutputRoot(url.path)
                }
                ancestor = parent
            }
        }

        static var ownedDurableOutputRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".codex/evidence/phase10-scheduler-closure-2026-08-06",
                    isDirectory: true
                )
        }

        static func ensureOwnedDurableOutputRootForTest() throws -> URL {
            let root = ownedDurableOutputRoot
            if !FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            return root
        }

        var outputRootIdentity: String {
            explicitOutputRoot?.standardizedFileURL.path ?? "temporary-phase10-owned"
        }
    }

    enum ConfigurationError: Error, LocalizedError {
        case invalidCount(name: String, value: Int, maximum: Int)
        case invalidEnvironment(name: String, value: String)
        case disallowedOutputRoot(String)
        case referenceMacGateRequiresExplicitOutputRoot
        case referenceMacGateRequiresIdentifier
        case referenceMacGateRequiresPerformance
        case referenceMacGateForbidsIdentifier
        case referenceMacGateRequiresSevenSamples

        var errorDescription: String? {
            switch self {
            case let .invalidCount(name, value, maximum):
                "\(name) must be in 1...\(maximum); received \(value)."
            case let .invalidEnvironment(name, value):
                "\(name) has an invalid value: \(value)."
            case let .disallowedOutputRoot(path):
                "Phase 10 qualification output may not use an evidence or Phase 08/09 root: \(path)."
            case .referenceMacGateRequiresExplicitOutputRoot:
                "A reference-Mac threshold gate requires an explicit retained Phase 10 output root."
            case .referenceMacGateRequiresIdentifier:
                "A reference-Mac threshold gate requires an explicit reference-Mac identifier."
            case .referenceMacGateRequiresPerformance:
                "A reference-Mac threshold gate requires the performance cell to be enabled."
            case .referenceMacGateForbidsIdentifier:
                "A disabled reference-Mac threshold gate may not carry a reference-Mac identifier."
            case .referenceMacGateRequiresSevenSamples:
                "A reference-Mac threshold gate requires exactly seven performance samples."
            }
        }
    }

    enum OracleMode: String, Codable {
        case none
        case feasibility
        case lockedTieBreak
    }

    struct Scenario: Codable, Equatable {
        let label: String
        let seed: UInt64
        let input: SchedulerEngineInput
        let oracleMode: OracleMode
    }

    struct HardSelectorTopologyCase: Codable, Equatable {
        let workload: WorkloadPlacementRequirements
        let nodes: [SchedulerNode]
        let context: HardTopologySpreadContext
        let passingNodeID: UUID
        let absentNotInNodeID: UUID
        let skewedTopologyNodeID: UUID
    }

    enum IssueSeverity: String, Codable {
        case failure
        case diagnostic
    }

    enum IssueKind: String, Codable, Hashable {
        case engineError
        case decisionIdentity
        case hardPolicy
        case capacity
        case quota
        case preemption
        case determinism
        case starvationBound
        case churnBound
        case exactSafetyMismatch
        case exactTieBreakMismatch
        case intentionalOptimizationGap
        case hostileExpectation
        case harnessError
    }

    struct Issue: Codable, Equatable {
        let kind: IssueKind
        let severity: IssueSeverity
        let message: String
    }
}

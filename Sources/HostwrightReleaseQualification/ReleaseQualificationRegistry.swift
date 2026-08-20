import Foundation

private let releaseQualificationSecretScanExcludedDirectories: Set<String> = [
    ".git", ".build", ".swiftpm", ".codex", ".claude", "tmp",
]
import HostwrightCore

public enum ReleaseQualificationParserBoundaryTarget: String, Codable, Sendable {
    case qualificationContractJSON = "qualification-contract-json"
    case hostwrightEvidenceJSON = "hostwright-evidence-json"
}

public struct ReleaseQualificationParserBoundaryResult: Codable, Equatable, Sendable {
    public let target: ReleaseQualificationParserBoundaryTarget
    public let expectation: ReleaseQualificationCorpusExpectation
    public let accepted: Bool
    public let satisfied: Bool

    public init(
        target: ReleaseQualificationParserBoundaryTarget,
        expectation: ReleaseQualificationCorpusExpectation,
        accepted: Bool
    ) {
        self.target = target
        self.expectation = expectation
        self.accepted = accepted
        self.satisfied = expectation == .accept ? accepted : !accepted
    }
}

public enum ReleaseQualificationParserBoundaryHarness {
    public static func evaluate(
        data: Data,
        target: ReleaseQualificationParserBoundaryTarget
    ) -> Bool {
        switch target {
        case .qualificationContractJSON:
            do {
                _ = try ReleaseQualificationJSON.decode(
                    ReleaseQualificationBudget.self,
                    from: data
                )
                return true
            } catch {
                return false
            }
        case .hostwrightEvidenceJSON:
            do {
                let report = try ReleaseQualificationJSON.decode(
                    HostwrightEvidenceReport.self,
                    from: data
                )
                try report.validate()
                return true
            } catch {
                return false
            }
        }
    }

    public static func evaluate(
        data: Data,
        target: ReleaseQualificationParserBoundaryTarget,
        expectation: ReleaseQualificationCorpusExpectation
    ) -> ReleaseQualificationParserBoundaryResult {
        ReleaseQualificationParserBoundaryResult(
            target: target,
            expectation: expectation,
            accepted: evaluate(data: data, target: target)
        )
    }
}

public struct ReleaseQualificationSafeCheckResult:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let checkID: String
    public let status: ReleaseQualificationOutcomeStatus
    public let scannedBytes: Int
    public let blockers: [ReleaseQualificationBlocker]
    public let failures: [String]

    public init(
        checkID: String,
        status: ReleaseQualificationOutcomeStatus,
        scannedBytes: Int,
        blockers: [ReleaseQualificationBlocker],
        failures: [String]
    ) {
        self.checkID = checkID
        self.status = status
        self.scannedBytes = scannedBytes
        self.blockers = blockers
        self.failures = failures
    }

    public func validate() throws {
        guard checkID.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              scannedBytes >= 0,
              blockers.count <= ReleaseQualificationLimits.maximumBlockers,
              failures.count <= ReleaseQualificationLimits.maximumBlockers else {
            throw ReleaseQualificationContractError.invalid(
                field: "safeCheck",
                reason: "safe-check identity or bounds are invalid"
            )
        }
        for blocker in blockers { try blocker.validate() }
        guard failures.allSatisfy({
            !$0.isEmpty &&
                $0.utf8.count <= 1_024 &&
                $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "safeCheck.failures",
                reason: "safe-check failure detail is invalid"
            )
        }
        switch status {
        case .passed:
            guard blockers.isEmpty, failures.isEmpty else {
                throw ReleaseQualificationContractError.invalid(
                    field: "safeCheck.status",
                    reason: "passing safe checks cannot carry blockers or failures"
                )
            }
        case .failed:
            guard !failures.isEmpty else {
                throw ReleaseQualificationContractError.invalid(
                    field: "safeCheck.failures",
                    reason: "failed safe checks require a failure detail"
                )
            }
        case .blocked, .unavailable:
            guard !blockers.isEmpty else {
                throw ReleaseQualificationContractError.invalid(
                    field: "safeCheck.blockers",
                    reason: "blocked safe checks require an explicit blocker"
                )
            }
        default:
            throw ReleaseQualificationContractError.invalid(
                field: "safeCheck.status",
                reason: "safe checks cannot use an outcome reserved for evidence"
            )
        }
    }
}

struct ReleaseQualificationLicensePolicy:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    static let kindValue = "hostwright.release-qualification.license-policy"
    static let relativePath = "contracts/v0.0.2/license-policy.json"
    static let licenseTextPrefix = "contracts/v0.0.2/dependency-licenses/"
    static let maximumPolicyBytes = 256 * 1_024
    static let maximumLicenseTextBytes = 1 * 1_024 * 1_024
    static let directDependencyIdentities: Set<String> = [
        "containerization", "swift-certificates", "wasmkit", "yams",
    ]
    static let allowedLicenseExpressions: Set<String> = [
        "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "MIT",
    ]

    let entries: [ReleaseQualificationLicensePolicyEntry]
    let kind: String
    let schemaVersion: Int

    func validate() throws {
        guard kind == Self.kindValue,
              schemaVersion == 1,
              entries.count <= 64,
              entries == entries.sorted(by: { $0.identity < $1.identity }),
              entries.map(\.identity).count == Set(entries.map(\.identity)).count,
              entries.map(\.licenseTextPath).count ==
                  Set(entries.map(\.licenseTextPath)).count else {
            throw ReleaseQualificationContractError.invalid(
                field: "licensePolicy",
                reason: "license policy schema, ordering, or uniqueness is invalid"
            )
        }
        for entry in entries { try entry.validate() }
    }
}

struct ReleaseQualificationLicensePolicyEntry:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    let identity: String
    let licenseExpression: String
    let licenseTextPath: String
    let licenseTextSHA256: ReleaseQualificationSHA256
    let licenseTextSizeBytes: Int
    let location: String
    let revision: String
    let version: String

    func validate() throws {
        let expectedPath =
            ReleaseQualificationLicensePolicy.licenseTextPrefix + identity + "/LICENSE.txt"
        guard identity.range(
            of: "^[a-z0-9][a-z0-9._-]{0,127}$",
            options: .regularExpression
        ) != nil,
            Self.normalizedIdentity(for: location) == identity,
            ReleaseQualificationLicensePolicy.allowedLicenseExpressions.contains(
                licenseExpression
            ),
            licenseTextPath == expectedPath,
            ReleaseQualificationPath.isSafeRelative(licenseTextPath),
            (1...ReleaseQualificationLicensePolicy.maximumLicenseTextBytes).contains(
                licenseTextSizeBytes
            ),
            revision.range(
                of: "^[a-f0-9]{40}$",
                options: .regularExpression
            ) != nil,
            let semanticVersion = try? ReleaseQualificationSemanticVersion(
                parsing: version
            ),
            semanticVersion.description == version else {
            throw ReleaseQualificationContractError.invalid(
                field: "licensePolicy.entries",
                reason: "license receipt identity, pin, expression, path, or size is invalid"
            )
        }
        try licenseTextSHA256.validate()
    }

    private static func normalizedIdentity(for location: String) -> String? {
        guard location.utf8.count <= 512,
              location.range(
                  of: "^https://[a-z0-9][a-z0-9.-]*/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\.git$",
                  options: .regularExpression
              ) != nil,
              let repository = location.split(separator: "/").last,
              repository.hasSuffix(".git") else {
            return nil
        }
        return String(repository.dropLast(4)).lowercased()
    }
}

public struct ReleaseQualificationDefaultRegistry {
    public static let registry = makeRegistry()

    public static func makeRegistry() -> ReleaseQualificationRegistry {
        let parserBudget = ReleaseQualificationBudget(
            maximumDurationSeconds: 300,
            maximumCPUHours: 0,
            maximumInputBytes: 4 * 1_024 * 1_024,
            maximumOutputBytes: 1 * 1_024 * 1_024
        )
        let localBudget = ReleaseQualificationBudget(
            maximumDurationSeconds: 300,
            maximumCPUHours: 1,
            maximumInputBytes: ReleaseQualificationLimits.maximumSourceScanBytes,
            maximumOutputBytes: 1 * 1_024 * 1_024
        )
        let boundedPlanBudget = ReleaseQualificationBudget(
            maximumDurationSeconds: 86_400,
            maximumCPUHours: 24,
            maximumInputBytes: 64 * 1_024 * 1_024,
            maximumOutputBytes: 8 * 1_024 * 1_024
        )
        let validBudget = ReleaseQualificationCorpusIdentity(
            id: "qualification-budget-valid",
            relativePath:
                "Tests/HostwrightReleaseQualificationTests/Fixtures/corpus/qualification-budget-valid.json",
            sha256: try! ReleaseQualificationSHA256(
                "f49b5a0716547e377814960c305b5222ec819371be4026e936eefb597dc8e1b3"
            ),
            sizeBytes: 104,
            expectation: .accept
        )
        let unknownBudget = ReleaseQualificationCorpusIdentity(
            id: "qualification-budget-unknown-key",
            relativePath:
                "Tests/HostwrightReleaseQualificationTests/Fixtures/corpus/qualification-budget-unknown-key.json",
            sha256: try! ReleaseQualificationSHA256(
                "c3f78b50fd675280dfc39bedf2db360e1a75c1eeb47b2a55149982e611f57fa2"
            ),
            sizeBytes: 130,
            expectation: .reject
        )
        let validEvidence = ReleaseQualificationCorpusIdentity(
            id: "evidence-report-valid",
            relativePath:
                "Tests/HostwrightReleaseQualificationTests/Fixtures/corpus/evidence-report-valid.json",
            sha256: try! ReleaseQualificationSHA256(
                "2709f552c96c3590e143528a159e10b6be0364ce656dcb6d76ca15a252f30142"
            ),
            sizeBytes: 625,
            expectation: .accept
        )
        let unknownEvidence = ReleaseQualificationCorpusIdentity(
            id: "evidence-report-unknown-key",
            relativePath:
                "Tests/HostwrightReleaseQualificationTests/Fixtures/corpus/evidence-report-unknown-key.json",
            sha256: try! ReleaseQualificationSHA256(
                "e948170d463201604f90708c879ba366454b074566d5153618f3e7fa72210a7d"
            ),
            sizeBytes: 651,
            expectation: .reject
        )
        let documentationLinksValidator = ReleaseQualificationCorpusIdentity(
            id: "documentation-links-validator",
            relativePath: "scripts/check-doc-links.py",
            sha256: try! ReleaseQualificationSHA256(
                "feec8f5d501dcce89dcc6ee2b5b155dfd9b1dbb4408efb02399f9b2adfebf588"
            ),
            sizeBytes: 3_695,
            expectation: .accept
        )
        let documentationCurrentTruthValidator = ReleaseQualificationCorpusIdentity(
            id: "documentation-current-truth-validator",
            relativePath: "scripts/check-current-truth.py",
            sha256: try! ReleaseQualificationSHA256(
                "daca74e386c58412b704b13f67ff836907968866639baabd094f01ba4e7463fe"
            ),
            sizeBytes: 14_047,
            expectation: .accept
        )
        return ReleaseQualificationRegistry(lanes: [
            ReleaseQualificationLane(
                id: "dependency-lock-integrity",
                kind: .dependency,
                target: "canonical direct pins and structural Package.resolved schema",
                executionMode: .safeLocal,
                authority: .local,
                requiredEvidenceClasses: [.unitContract, .localIntegration],
                budget: localBudget,
                corpus: [],
                exclusions: [
                    "does not establish upstream provenance or independent assessment"
                ]
            ),
            ReleaseQualificationLane(
                id: "evidence-json-boundary",
                kind: .parserFuzz,
                target: "HostwrightEvidenceReport strict canonical JSON decoder",
                executionMode: .safeLocal,
                authority: .local,
                requiredEvidenceClasses: [.unitContract],
                budget: parserBudget,
                corpus: [validEvidence, unknownEvidence],
                exclusions: [
                    "does not claim protocol fuzzing or long-duration fuzzing"
                ]
            ),
            ReleaseQualificationLane(
                id: "phase08-protocol-fuzz",
                kind: .protocolFuzz,
                target: "Apple container protocol adapter",
                executionMode: .liveRuntime,
                authority: .phase08Runtime,
                requiredEvidenceClasses: [.liveRuntime, .interopConformance],
                budget: boundedPlanBudget,
                corpus: [],
                exclusions: [
                    "Phase 08 runtime authority is released, but no explicit bounded fuzzing provider is wired"
                ]
            ),
            ReleaseQualificationLane(
                id: "qualification-json-boundary",
                kind: .parserFuzz,
                target: "HostwrightReleaseQualification strict canonical JSON decoder",
                executionMode: .safeLocal,
                authority: .local,
                requiredEvidenceClasses: [.unitContract],
                budget: parserBudget,
                corpus: [validBudget, unknownBudget],
                exclusions: [
                    "does not claim protocol fuzzing or long-duration fuzzing"
                ]
            ),
            ReleaseQualificationLane(
                id: "sanitizer-asan",
                kind: .sanitizer,
                target: "AddressSanitizer qualification lane",
                executionMode: .heavy,
                authority: .futureProvider,
                requiredEvidenceClasses: [.unitContract, .localIntegration],
                budget: boundedPlanBudget,
                corpus: [],
                exclusions: [
                    "no ASan provider is wired in this additive slice"
                ]
            ),
            ReleaseQualificationLane(
                id: "sanitizer-tsan",
                kind: .sanitizer,
                target: "ThreadSanitizer qualification lane",
                executionMode: .heavy,
                authority: .futureProvider,
                requiredEvidenceClasses: [.unitContract, .localIntegration],
                budget: boundedPlanBudget,
                corpus: [],
                exclusions: [
                    "no TSan provider is wired in this additive slice"
                ]
            ),
            ReleaseQualificationLane(
                id: "sast-semgrep",
                kind: .sast,
                target: "Semgrep source-analysis lane",
                executionMode: .safeLocal,
                authority: .local,
                requiredEvidenceClasses: [.securityAssessment],
                budget: localBudget,
                corpus: [],
                exclusions: [
                    "tool presence alone is not SAST evidence"
                ]
            ),
            ReleaseQualificationLane(
                id: "secret-scan",
                kind: .secret,
                target: "bounded high-confidence secret-pattern scan",
                executionMode: .safeLocal,
                authority: .local,
                requiredEvidenceClasses: [.securityAssessment],
                budget: localBudget,
                corpus: [],
                exclusions: [
                    "not a complete independent secret-management assessment"
                ]
            ),
            ReleaseQualificationLane(
                id: "license-policy",
                kind: .license,
                target: "exact direct-dependency license policy receipts",
                executionMode: .safeLocal,
                authority: .local,
                requiredEvidenceClasses: [.localIntegration],
                budget: localBudget,
                corpus: [],
                exclusions: [
                    "does not assert legal compliance or license compatibility",
                    "does not establish transitive dependency license completeness",
                    "does not fetch or infer upstream license metadata"
                ]
            ),
            ReleaseQualificationLane(
                id: "documentation-source-contracts",
                kind: .dependency,
                target: "repository documentation links and current public truth",
                executionMode: .safeLocal,
                authority: .local,
                requiredEvidenceClasses: [.localIntegration],
                budget: localBudget,
                corpus: [documentationLinksValidator, documentationCurrentTruthValidator],
                exclusions: [
                    "does not qualify CLI or example quickstarts",
                    "does not qualify clean-system live runtime examples",
                    "does not qualify screenshots, search, or accessibility",
                    "does not qualify the separately deployed website"
                ]
            )
        ])
    }
}

public struct ReleaseQualificationRegistryPlanner: Sendable {
    public let registry: ReleaseQualificationRegistry
    private let pythonLocator: any ReleaseQualificationPythonLocating
    private let localLaneRunner: ReleaseQualificationLocalLaneRunner

    public init(
        registry: ReleaseQualificationRegistry = ReleaseQualificationDefaultRegistry.registry,
        pythonLocator: any ReleaseQualificationPythonLocating =
            ReleaseQualificationTrustedPythonLocator(),
        localLaneRunner: ReleaseQualificationLocalLaneRunner =
            ReleaseQualificationLocalLaneRunner()
    ) {
        self.registry = registry
        self.pythonLocator = pythonLocator
        self.localLaneRunner = localLaneRunner
    }

    public func plan(
        sourceRoot: URL,
        environment: ReleaseQualificationDetectedEnvironment? = nil
    ) throws -> ReleaseQualificationPlanDocument {
        guard ReleaseQualificationPath.isNormalizedAbsolute(sourceRoot.path),
              try ReleaseQualificationFile.isDirectory(sourceRoot) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        try registry.validate()
        let lanePlans = try registry.lanes.map { lane in
            try plan(lane: lane, sourceRoot: sourceRoot, environment: environment)
        }
        let document = ReleaseQualificationPlanDocument(
            matrix: ReleaseQualificationSupportedMatrix.committed,
            registry: registry,
            lanes: lanePlans
        )
        try document.validate()
        return document
    }

    private func plan(
        lane: ReleaseQualificationLane,
        sourceRoot: URL,
        environment: ReleaseQualificationDetectedEnvironment?
    ) throws -> ReleaseQualificationLanePlan {
        var blockers: [ReleaseQualificationBlocker] = []
        var observed: [ReleaseQualificationCorpusIdentity] = []
        for corpus in lane.corpus {
            let url = sourceRoot.appendingPathComponent(corpus.relativePath)
            guard ReleaseQualificationPath.isContained(url, in: sourceRoot),
                  try ReleaseQualificationFile.isRegularNonSymlink(url) else {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .missingCorpus,
                        field: "registry.\(lane.id).corpus.\(corpus.id)",
                        detail: "seeded corpus file is missing or is not a regular file"
                    )
                )
                continue
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            guard size == corpus.sizeBytes else {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .corpusMismatch,
                        field: "registry.\(lane.id).corpus.\(corpus.id).sizeBytes",
                        detail: "seeded corpus size does not match its committed identity"
                    )
                )
                continue
            }
            guard try ReleaseQualificationHash.sha256(fileURL: url) == corpus.sha256 else {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .tamperedEvidence,
                        field: "registry.\(lane.id).corpus.\(corpus.id).sha256",
                        detail: "seeded corpus hash does not match its committed identity"
                    )
                )
                continue
            }
            observed.append(corpus)
        }

        switch lane.kind {
        case .parserFuzz:
            break
        case .protocolFuzz:
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: .fuzzingProviderUnavailable,
                    field: "registry.\(lane.id).provider",
                    detail: "no explicit protocol fuzzing provider is authorized in this slice"
                )
            )
        case .sanitizer:
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: .sanitizerUnavailable,
                    field: "registry.\(lane.id).provider",
                    detail: "ASan/TSan execution requires a future explicit provider"
                )
            )
        case .dependency:
            if lane.id == "documentation-source-contracts" {
                let scripts = [
                    sourceRoot.appendingPathComponent("scripts/check-doc-links.py"),
                    sourceRoot.appendingPathComponent("scripts/check-current-truth.py")
                ]
                let scriptsAreRegular = try scripts.allSatisfy {
                    guard ReleaseQualificationPath.isContained($0, in: sourceRoot) else {
                        return false
                    }
                    return try ReleaseQualificationFile.isRegularNonSymlink($0)
                }
                if !scriptsAreRegular || pythonLocator.python3Path() == nil {
                    blockers.append(
                        ReleaseQualificationBlocker(
                            reason: .dependencyUnavailable,
                            field: "registry.\(lane.id).provider",
                            detail: "the bounded repository documentation provider is unavailable"
                        )
                    )
                }
            }
        case .secret:
            break
        case .sast:
            let semgrepAvailable =
                environment?.tool(.semgrep)?.availability.status == .available
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: semgrepAvailable ? .missingExplicitAuthority : .sastToolUnavailable,
                    field: "registry.\(lane.id).provider",
                    detail: semgrepAvailable
                        ? "a discovered tool is not evidence until a bounded provider is explicitly wired"
                        : "Semgrep is not safely available for this host"
                )
            )
        case .license:
            if lane.id == "license-policy" {
                if environment?.source.availability.status != .available ||
                    environment?.source.commit == nil ||
                    environment?.source.dirty == nil {
                    blockers.append(
                        ReleaseQualificationBlocker(
                            reason: .sourceCommitUnavailable,
                            field: "environment.source",
                            detail: "license-policy execution requires an exact source commit and dirty-state identity"
                        )
                    )
                } else if environment?.source.dirty == true {
                    blockers.append(
                        ReleaseQualificationBlocker(
                            reason: .dirtySource,
                            field: "environment.source",
                            detail: "dirty source cannot satisfy the license-policy lane"
                        )
                    )
                } else if let sourceCommit = environment?.source.commit {
                    let execution = try localLaneRunner.run(
                        lane: lane,
                        sourceRoot: sourceRoot,
                        sourceCommit: sourceCommit
                    )
                    blockers.append(contentsOf: licensePolicyPlanningBlockers(execution))
                }
            } else {
                blockers.append(
                    ReleaseQualificationBlocker(
                        reason: .licenseMetadataUnavailable,
                        field: "registry.\(lane.id).provider",
                        detail: "no bounded dependency license-policy provider is wired"
                    )
                )
            }
        default:
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: .missingExplicitAuthority,
                    field: "registry.\(lane.id).provider",
                    detail: "this lane is plan-visible but has no executable provider"
                )
            )
        }

        let uniqueBlockers = Array(Set(blockers)).sorted {
            ($0.field, $0.reason.rawValue, $0.detail) <
                ($1.field, $1.reason.rawValue, $1.detail)
        }
        return ReleaseQualificationLanePlan(
            laneID: lane.id,
            status: uniqueBlockers.isEmpty ? .ready : .blocked,
            blockers: uniqueBlockers,
            observedCorpus: observed
        )
    }

    private func licensePolicyPlanningBlockers(
        _ execution: ReleaseQualificationLaneExecution
    ) -> [ReleaseQualificationBlocker] {
        if execution.status == .passed,
           execution.blockers.isEmpty,
           execution.failures.isEmpty {
            return []
        }
        if !execution.blockers.isEmpty {
            return execution.blockers
        }
        return [
            ReleaseQualificationBlocker(
                reason: .tamperedEvidence,
                field: "registry.license-policy.provider",
                detail: "the exact committed license-policy inputs fail integrity validation"
            )
        ]
    }

}

public struct ReleaseQualificationLaneExecution: Equatable, Sendable {
    public let laneID: String
    public let status: ReleaseQualificationOutcomeStatus
    public let commands: [ReleaseQualificationCommandObservation]
    public let blockers: [ReleaseQualificationBlocker]
    public let failures: [String]

    public init(
        laneID: String,
        status: ReleaseQualificationOutcomeStatus,
        commands: [ReleaseQualificationCommandObservation],
        blockers: [ReleaseQualificationBlocker],
        failures: [String]
    ) {
        self.laneID = laneID
        self.status = status
        self.commands = commands
        self.blockers = blockers.sorted {
            ($0.field, $0.reason.rawValue, $0.detail) <
                ($1.field, $1.reason.rawValue, $1.detail)
        }
        self.failures = failures.sorted()
    }

    public func validate() throws {
        guard laneID.range(
            of: "^[a-z0-9][a-z0-9._-]{0,127}$",
            options: .regularExpression
        ) != nil,
            commands.count <= ReleaseQualificationLimits.maximumCommandCount,
            blockers.count <= ReleaseQualificationLimits.maximumBlockers,
            failures.count <= ReleaseQualificationLimits.maximumBlockers,
            blockers == blockers.sorted(by: {
                ($0.field, $0.reason.rawValue, $0.detail) <
                    ($1.field, $1.reason.rawValue, $1.detail)
            }),
            failures == failures.sorted() else {
            throw ReleaseQualificationContractError.invalid(
                field: "laneExecution",
                reason: "lane execution identity, ordering, or bounds are invalid"
            )
        }
        for command in commands { try command.validate() }
        for blocker in blockers { try blocker.validate() }
        guard failures.allSatisfy({
            !$0.isEmpty &&
                $0.utf8.count <= 1_024 &&
                $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "laneExecution.failures",
                reason: "lane execution failure detail is invalid"
            )
        }
        switch status {
        case .passed:
            guard blockers.isEmpty, failures.isEmpty, !commands.isEmpty else {
                throw ReleaseQualificationContractError.invalid(
                    field: "laneExecution.status",
                    reason: "passing lane execution requires command evidence only"
                )
            }
        case .failed:
            guard !failures.isEmpty, !commands.isEmpty else {
                throw ReleaseQualificationContractError.invalid(
                    field: "laneExecution.status",
                    reason: "failed lane execution requires a command and fixed failure"
                )
            }
        case .blocked, .unavailable:
            guard !blockers.isEmpty else {
                throw ReleaseQualificationContractError.invalid(
                    field: "laneExecution.status",
                    reason: "blocked lane execution requires an explicit blocker"
                )
            }
        default:
            throw ReleaseQualificationContractError.invalid(
                field: "laneExecution.status",
                reason: "local lane execution cannot use this evidence-only status"
            )
        }
    }
}

public protocol ReleaseQualificationPythonLocating: Sendable {
    func python3Path() -> String?
}

public struct ReleaseQualificationTrustedPythonLocator:
    ReleaseQualificationPythonLocating,
    Sendable
{
    public init() {}

    public func python3Path() -> String? {
        do {
            return try SecureExecutableResolver.resolve(
                named: "python3",
                searchPath: ReleaseQualificationExecutableLocator.trustedSearchPath,
                ownershipPolicy: .rootOnly
            )?.path
        } catch {
            return nil
        }
    }
}

public struct ReleaseQualificationLocalLaneRunner: Sendable {
    private static let validatedPythonSourceRunner =
        "import base64,hashlib,json,sys;path=sys.argv[1];payload=sys.stdin.buffer.read();" +
        "size=int.from_bytes(payload[:8],'big');source=payload[8:8+size];snapshot=payload[8+size:];" +
        "hashlib.sha256(source).hexdigest()==sys.argv[2] or sys.exit(86);" +
        "hashlib.sha256(snapshot).hexdigest()==sys.argv[3] or sys.exit(87);" +
        "document=json.loads(snapshot);files={p:base64.b64decode(v,validate=True) " +
        "for p,v in document['files'].items()};entries=frozenset(document['entries']);" +
        "sys.argv=[path]+sys.argv[4:];" +
        "namespace={'__name__':'__main__','__file__':path,'__package__':None," +
        "'HOSTWRIGHT_QUALIFICATION_FILES':files," +
        "'HOSTWRIGHT_QUALIFICATION_ENTRIES':entries," +
        "'__cached__':None};exec(compile(source,path,'exec'),namespace,namespace)"

    private static let documentationSnapshotPaths: Set<String> = [
        "README.md",
        "Sources/HostwrightCore/CapabilityCatalog.swift",
        "Sources/HostwrightCore/ContractVersions.swift",
        "Sources/HostwrightCore/EvidenceModels.swift",
        "Sources/HostwrightCore/HostwrightIdentity.swift",
        "contracts/v0.0.2/README.md",
        "contracts/v0.0.2/versions.json",
        "docs/BUILD_STATUS.md",
        "docs/IMPLEMENTATION_PLAN.md",
        "docs/architecture/documentation-site-public-education.md",
        "docs/architecture/plugin-extension-architecture.md",
        "docs/architecture/runtime-adapter.md",
        "docs/architecture/state-store.md",
        "docs/design/adr-0007-resource-identity-provider-binding.md",
        "docs/reference/cli.md",
        "docs/reference/compatibility.md",
        "docs/reference/install.md",
        "docs/reference/limitations.md",
        "docs/reference/manifest.md",
        "docs/release/IMMUTABLE_RELEASES.json",
        "docs/release/RELEASE_PROCESS.md",
        "docs/release/beta-readiness.md",
        "docs/requirements/ACCEPTANCE_MATRIX.md",
        "docs/requirements/REQUIREMENTS.md",
        "docs/requirements/SOURCE_TRACEABILITY.md",
        "docs/roadmap/v0.0.2/IMPLEMENTATION_PLAN.md",
        "docs/roadmap/v0.0.2/issues.json",
        "schemas/hostwright-evidence.schema.json",
        "schemas/hostwright-yaml.schema.json",
    ]

    private let commandRunner: any ReleaseQualificationStandardInputCommandRunning
    private let sourceSnapshotRunner: any ReleaseQualificationStandardInputCommandRunning
    private let commandLimits: ReleaseQualificationCommandLimits
    private let pythonLocator: any ReleaseQualificationPythonLocating

    public init(
        commandRunner: any ReleaseQualificationStandardInputCommandRunning =
            ReleaseQualificationSubprocessRunner(),
        sourceSnapshotRunner: any ReleaseQualificationStandardInputCommandRunning =
            ReleaseQualificationSubprocessRunner(),
        commandLimits: ReleaseQualificationCommandLimits = try! ReleaseQualificationCommandLimits(
            timeoutMilliseconds: 300_000
        ),
        pythonLocator: any ReleaseQualificationPythonLocating =
            ReleaseQualificationTrustedPythonLocator()
    ) {
        self.commandRunner = commandRunner
        self.sourceSnapshotRunner = sourceSnapshotRunner
        self.commandLimits = commandLimits
        self.pythonLocator = pythonLocator
    }

    public func run(
        lane: ReleaseQualificationLane,
        sourceRoot: URL,
        sourceCommit: ReleaseQualificationCommit,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ReleaseQualificationLaneExecution {
        try lane.validate()
        guard ReleaseQualificationPath.isNormalizedAbsolute(sourceRoot.path),
              try ReleaseQualificationFile.isDirectory(sourceRoot) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        guard !cancellation.isCancelled else {
            throw ReleaseQualificationContractError.cancelled
        }
        guard ReleaseQualificationDefaultRegistry.registry.lanes.contains(lane) else {
            return try validated(
                ReleaseQualificationLaneExecution(
                    laneID: lane.id,
                    status: .blocked,
                    commands: [],
                    blockers: [
                        ReleaseQualificationBlocker(
                            reason: .missingExplicitAuthority,
                            field: "registry.\(lane.id).provider",
                            detail: "lane contract does not exactly match the committed registry"
                        )
                    ],
                    failures: []
                )
            )
        }
        if lane.id == "dependency-lock-integrity" ||
            lane.id == "license-policy" ||
            lane.id == "secret-scan" {
            return try runExactCommitSafeCheck(
                lane: lane,
                sourceRoot: sourceRoot,
                sourceCommit: sourceCommit,
                cancellation: cancellation
            )
        }
        guard lane.id == "documentation-source-contracts",
              lane.kind == .dependency,
              lane.executionMode == .safeLocal,
              lane.authority == .local else {
            return try validated(
                ReleaseQualificationLaneExecution(
                    laneID: lane.id,
                    status: .blocked,
                    commands: [],
                    blockers: [
                        ReleaseQualificationBlocker(
                            reason: .missingExplicitAuthority,
                            field: "registry.\(lane.id).provider",
                            detail: "no bounded local provider is wired for this lane"
                        )
                    ],
                    failures: []
                )
            )
        }
        let scriptPaths = [
            "scripts/check-doc-links.py",
            "scripts/check-current-truth.py"
        ]
        let providerCorpus = lane.corpus.filter { scriptPaths.contains($0.relativePath) }
        guard lane.corpus.count == scriptPaths.count,
              providerCorpus.count == scriptPaths.count,
              Set(providerCorpus.map(\.relativePath)) == Set(scriptPaths),
              providerCorpus.allSatisfy({ $0.expectation == .accept }) else {
            return try blockedDocumentationExecution(
                laneID: lane.id,
                reason: .missingCorpus,
                detail: "documentation validators lack exact committed source identities"
            )
        }
        var sources: [String: Data] = [:]
        for path in scriptPaths {
            guard let identity = providerCorpus.first(where: { $0.relativePath == path }) else {
                return try blockedDocumentationExecution(
                    laneID: lane.id,
                    reason: .dependencyUnavailable,
                    detail: "documentation source validators are unavailable or unsafe"
                )
            }
            let data: Data
            do {
                data = try ReleaseQualificationFile.readBoundedRegularFile(
                    relativePath: path,
                    under: sourceRoot
                )
            } catch {
                return try blockedDocumentationExecution(
                    laneID: lane.id,
                    reason: .dependencyUnavailable,
                    detail: "documentation source validators are unavailable or unsafe"
                )
            }
            guard data.count == identity.sizeBytes else {
                return try blockedDocumentationExecution(
                    laneID: lane.id,
                    reason: .corpusMismatch,
                    detail: "documentation validator size differs from its committed identity"
                )
            }
            guard ReleaseQualificationHash.sha256(data: data) == identity.sha256 else {
                return try blockedDocumentationExecution(
                    laneID: lane.id,
                    reason: .tamperedEvidence,
                    detail: "documentation validator hash differs from its committed identity"
                )
            }
            sources[path] = data
        }
        guard let pythonPath = pythonLocator.python3Path() else {
            return try unavailableDocumentationExecution(laneID: lane.id)
        }
        var observations: [ReleaseQualificationCommandObservation] = []
        let sourceSnapshot: Data
        do {
            sourceSnapshot = try documentationSnapshot(
                sourceRoot: sourceRoot,
                sourceCommit: sourceCommit,
                observations: &observations,
                cancellation: cancellation
            )
        } catch {
            return try validated(
                ReleaseQualificationLaneExecution(
                    laneID: lane.id,
                    status: .blocked,
                    commands: observations,
                    blockers: [
                        ReleaseQualificationBlocker(
                            reason: .tamperedEvidence,
                            field: "registry.\(lane.id).sourceSnapshot",
                            detail: "the exact committed documentation input snapshot is unavailable"
                        )
                    ],
                    failures: []
                )
            )
        }
        let snapshotSHA256 = ReleaseQualificationHash.sha256(data: sourceSnapshot)
        let commandSpecs: [(String, [String], String)] = [
            (
                scriptPaths[0],
                ["README.md", "docs"],
                "validate repository documentation links"
            ),
            (scriptPaths[1], [], "validate current public documentation truth")
        ]
        do {
            for (scriptPath, scriptArguments, purpose) in commandSpecs {
                guard let source = sources[scriptPath],
                      let identity = providerCorpus.first(where: {
                          $0.relativePath == scriptPath
                      }) else {
                    return try blockedDocumentationExecution(
                        laneID: lane.id,
                        reason: .missingCorpus,
                        detail: "documentation validator identity became unavailable"
                    )
                }
                let command = try ReleaseQualificationCommandIdentity(
                    executablePath: pythonPath,
                    arguments: [
                        "-c",
                        Self.validatedPythonSourceRunner,
                        sourceRoot.appendingPathComponent(scriptPath).path,
                        identity.sha256.value,
                        snapshotSHA256.value,
                    ] + scriptArguments,
                    workingDirectory: sourceRoot.path,
                    purpose: purpose
                )
                let startedAt = ReleaseQualificationTimestamp()
                var sourceSize = UInt64(source.count).bigEndian
                var payload = Data(bytes: &sourceSize, count: MemoryLayout<UInt64>.size)
                payload.append(source)
                payload.append(sourceSnapshot)
                guard payload.count <= ReleaseQualificationLimits.maximumSourceFileBytes else {
                    throw ReleaseQualificationCommandError.outputLimitExceeded
                }
                let result = try commandRunner.run(
                    command,
                    standardInput: payload,
                    limits: commandLimits,
                    cancellation: cancellation
                )
                let observation = ReleaseQualificationCommandObservation(
                    identity: command,
                    startedAt: startedAt,
                    endedAt: ReleaseQualificationTimestamp(),
                    durationMilliseconds: result.durationMilliseconds,
                    exitStatus: result.exitStatus,
                    standardOutputSHA256: ReleaseQualificationHash.sha256(
                        data: result.standardOutput
                    ),
                    standardErrorSHA256: ReleaseQualificationHash.sha256(
                        data: result.standardError
                    ),
                    standardOutputBytes: result.standardOutput.count,
                    standardErrorBytes: result.standardError.count,
                    standardOutputTruncated: result.standardOutputTruncated,
                    standardErrorTruncated: result.standardErrorTruncated
                )
                observations.append(observation)
                if result.standardOutputTruncated || result.standardErrorTruncated {
                    return try validated(
                        ReleaseQualificationLaneExecution(
                            laneID: lane.id,
                            status: .blocked,
                            commands: observations,
                            blockers: [
                                ReleaseQualificationBlocker(
                                    reason: .outputLimitExceeded,
                                    field: "registry.\(lane.id).output",
                                    detail: "documentation qualification exceeded its bounded output"
                                )
                            ],
                            failures: []
                        )
                    )
                }
                if result.exitStatus != 0 {
                    return try validated(
                        ReleaseQualificationLaneExecution(
                            laneID: lane.id,
                            status: .failed,
                            commands: observations,
                            blockers: [],
                            failures: ["documentation source contract command failed"]
                        )
                    )
                }
            }
            return try validated(
                ReleaseQualificationLaneExecution(
                    laneID: lane.id,
                    status: .passed,
                    commands: observations,
                    blockers: [],
                    failures: []
                )
            )
        } catch let error as ReleaseQualificationCommandError {
            let reason: ReleaseQualificationUnsupportedReason
            switch error {
            case .cancelled:
                throw ReleaseQualificationContractError.cancelled
            case .outputLimitExceeded:
                reason = .outputLimitExceeded
            case .unavailable:
                reason = .dependencyUnavailable
            case .timedOut, .failed:
                reason = .unavailableFact
            }
            return try validated(
                ReleaseQualificationLaneExecution(
                    laneID: lane.id,
                    status: .blocked,
                    commands: observations,
                    blockers: [
                        ReleaseQualificationBlocker(
                            reason: reason,
                            field: "registry.\(lane.id).provider",
                            detail: "documentation qualification could not produce bounded command evidence"
                        )
                    ],
                    failures: []
                )
            )
        }
    }

    private func runExactCommitSafeCheck(
        lane: ReleaseQualificationLane,
        sourceRoot: URL,
        sourceCommit: ReleaseQualificationCommit,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationLaneExecution {
        let expectedKind: ReleaseQualificationLaneKind? = switch lane.id {
        case "dependency-lock-integrity": .dependency
        case "license-policy": .license
        case "secret-scan": .secret
        default: nil
        }
        guard let expectedKind,
              lane.kind == expectedKind,
              lane.executionMode == .safeLocal,
              lane.authority == .local else {
            return try blockedLocalExecution(
                laneID: lane.id,
                reason: .missingExplicitAuthority,
                detail: "no bounded local provider is wired for this lane"
            )
        }

        var observations: [ReleaseQualificationCommandObservation] = []
        do {
            let gitPath = try trustedGitPath()
            let tree = try committedSafeCheckTreeEntries(
                sourceRoot: sourceRoot,
                sourceCommit: sourceCommit,
                gitPath: gitPath,
                purpose: "snapshot committed safe-check input names",
                observations: &observations,
                cancellation: cancellation
            )
            let entries = tree.regularEntries
            let selected: [DocumentationTreeEntry]
            switch lane.id {
            case "dependency-lock-integrity":
                let required = Set(["Package.swift", "Package.resolved"])
                selected = entries.filter { required.contains($0.path) }
                guard Set(selected.map(\.path)) == required else {
                    return try blockedLocalExecution(
                        laneID: lane.id,
                        reason: .dependencyUnavailable,
                        detail: "the exact commit does not contain Package.swift and Package.resolved",
                        commands: observations
                    )
                }
            case "license-policy":
                let required = Set([
                    "Package.swift",
                    "Package.resolved",
                    ReleaseQualificationLicensePolicy.relativePath,
                ])
                let unsafeInputs = tree.nonRegularPaths.filter {
                    required.contains($0) ||
                        $0.hasPrefix(ReleaseQualificationLicensePolicy.licenseTextPrefix)
                }
                guard unsafeInputs.isEmpty else {
                    return try blockedLocalExecution(
                        laneID: lane.id,
                        reason: .unsafePath,
                        detail: "the exact committed license-policy input is nonregular at \(unsafeInputs[0])",
                        commands: observations
                    )
                }
                let requiredEntries = entries.filter { required.contains($0.path) }
                guard Set(requiredEntries.map(\.path)) == required else {
                    return try blockedLocalExecution(
                        laneID: lane.id,
                        reason: .licenseMetadataUnavailable,
                        detail: "the exact commit is missing \(ReleaseQualificationLicensePolicy.relativePath), Package.swift, or Package.resolved",
                        commands: observations
                    )
                }
                guard requiredEntries.allSatisfy({ entry in
                    entry.path != ReleaseQualificationLicensePolicy.relativePath ||
                        entry.size <= ReleaseQualificationLicensePolicy.maximumPolicyBytes
                }) else {
                    return try blockedLocalExecution(
                        laneID: lane.id,
                        reason: .outputLimitExceeded,
                        detail: "the committed license-policy receipt exceeds its bounded size",
                        commands: observations
                    )
                }
                let licenseEntries = entries.filter {
                    $0.path.hasPrefix(ReleaseQualificationLicensePolicy.licenseTextPrefix)
                }
                guard licenseEntries.count <= 64,
                      licenseEntries.allSatisfy({
                          $0.size <= ReleaseQualificationLicensePolicy.maximumLicenseTextBytes
                      }) else {
                    return try blockedLocalExecution(
                        laneID: lane.id,
                        reason: .outputLimitExceeded,
                        detail: "the committed license-policy text set exceeds its bounded size",
                        commands: observations
                    )
                }
                selected = (requiredEntries + licenseEntries).sorted { $0.path < $1.path }
            case "secret-scan":
                selected = entries.filter { entry in
                    !entry.path.split(separator: "/").contains { component in
                        releaseQualificationSecretScanExcludedDirectories.contains(
                            String(component)
                        )
                    }
                }
                guard !selected.isEmpty else {
                    return try blockedLocalExecution(
                        laneID: lane.id,
                        reason: .secretScanUnavailable,
                        detail: "the exact commit contains no eligible regular files",
                        commands: observations
                    )
                }
            default:
                return try blockedLocalExecution(
                    laneID: lane.id,
                    reason: .missingExplicitAuthority,
                    detail: "no bounded local provider is wired for this lane",
                    commands: observations
                )
            }
            let files = try committedFiles(
                selected,
                sourceRoot: sourceRoot,
                gitPath: gitPath,
                purpose: "snapshot committed safe-check input bytes",
                observations: &observations,
                cancellation: cancellation
            )
            let result = try ReleaseQualificationSafeCheckRunner().run(
                checkID: lane.id,
                immutableFiles: files,
                cancellation: cancellation
            )
            return try validated(
                ReleaseQualificationLaneExecution(
                    laneID: lane.id,
                    status: result.status,
                    commands: observations,
                    blockers: result.blockers,
                    failures: result.failures
                )
            )
        } catch ReleaseQualificationContractError.cancelled {
            throw ReleaseQualificationContractError.cancelled
        } catch ReleaseQualificationContractError.oversizedInput {
            return try blockedLocalExecution(
                laneID: lane.id,
                reason: .outputLimitExceeded,
                detail: "the exact committed safe-check input exceeds its bounded source budget",
                commands: observations
            )
        } catch let error as ReleaseQualificationCommandError {
            if error == .cancelled {
                throw ReleaseQualificationContractError.cancelled
            }
            return try blockedLocalExecution(
                laneID: lane.id,
                reason: error == .outputLimitExceeded ? .outputLimitExceeded : .dependencyUnavailable,
                detail: "the exact committed safe-check input is unavailable",
                commands: observations
            )
        } catch {
            return try blockedLocalExecution(
                laneID: lane.id,
                reason: .tamperedEvidence,
                detail: "the exact committed safe-check input failed integrity validation",
                commands: observations
            )
        }
    }

    private struct DocumentationTreeEntry {
        let path: String
        let objectID: String
        let size: Int
    }

    private struct SafeCheckTree {
        let regularEntries: [DocumentationTreeEntry]
        let nonRegularPaths: [String]
    }

    private func trustedGitPath() throws -> String {
        guard let path = try SecureExecutableResolver.resolve(
            named: "git",
            searchPath: ReleaseQualificationExecutableLocator.trustedSearchPath,
            ownershipPolicy: .rootOnly
        )?.path else {
            throw ReleaseQualificationCommandError.unavailable
        }
        return path
    }

    private func committedSafeCheckTreeEntries(
        sourceRoot: URL,
        sourceCommit: ReleaseQualificationCommit,
        gitPath: String,
        purpose: String,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) throws -> SafeCheckTree {
        let command = try ReleaseQualificationCommandIdentity(
            executablePath: gitPath,
            arguments: [
                "--no-replace-objects", "-C", sourceRoot.path,
                "ls-tree", "-r", "-z", "--long", "--full-tree", sourceCommit.value,
            ],
            workingDirectory: sourceRoot.path,
            purpose: purpose
        )
        let result = try runSnapshotCommand(
            command,
            standardInput: nil,
            maximumOutputBytes: ReleaseQualificationLimits.maximumOutputBytes,
            observations: &observations,
            cancellation: cancellation
        )
        return try parseSafeCheckTree(result.standardOutput)
    }

    private func committedFiles(
        _ entries: [DocumentationTreeEntry],
        sourceRoot: URL,
        gitPath: String,
        purpose: String,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) throws -> [String: Data] {
        guard !entries.isEmpty,
              entries.count <= 4_096,
              entries.map(\.path).count == Set(entries.map(\.path)).count else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        var objectSizes: [String: Int] = [:]
        var totalBytes = 0
        for entry in entries {
            totalBytes += entry.size
            guard totalBytes <= ReleaseQualificationLimits.maximumSourceScanBytes else {
                throw ReleaseQualificationContractError.oversizedInput
            }
            if let existing = objectSizes[entry.objectID] {
                guard existing == entry.size else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
            } else {
                objectSizes[entry.objectID] = entry.size
            }
        }
        let objectGroups = try partitionDocumentationObjects(objectSizes)
        var blobs: [String: Data] = [:]
        for objectIDs in objectGroups {
            let batchInput = Data((objectIDs.joined(separator: "\n") + "\n").utf8)
            let command = try ReleaseQualificationCommandIdentity(
                executablePath: gitPath,
                arguments: [
                    "--no-replace-objects", "-C", sourceRoot.path,
                    "cat-file", "--batch",
                ],
                workingDirectory: sourceRoot.path,
                purpose: batchPurpose(purpose, request: batchInput)
            )
            let result = try runSnapshotCommand(
                command,
                standardInput: batchInput,
                maximumOutputBytes: ReleaseQualificationLimits.maximumOutputBytes,
                observations: &observations,
                cancellation: cancellation
            )
            let group = try parseDocumentationBlobs(
                result.standardOutput,
                expectedObjectIDs: objectIDs
            )
            for (objectID, blob) in group {
                guard blobs.updateValue(blob, forKey: objectID) == nil else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
            }
        }
        var files: [String: Data] = [:]
        for entry in entries {
            guard let blob = blobs[entry.objectID], blob.count == entry.size,
                  files.updateValue(blob, forKey: entry.path) == nil else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
        }
        return files
    }

    private func documentationSnapshot(
        sourceRoot: URL,
        sourceCommit: ReleaseQualificationCommit,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) throws -> Data {
        guard let gitPath = try SecureExecutableResolver.resolve(
            named: "git",
            searchPath: ReleaseQualificationExecutableLocator.trustedSearchPath,
            ownershipPolicy: .rootOnly
        )?.path else {
            throw ReleaseQualificationCommandError.unavailable
        }
        let treeCommand = try ReleaseQualificationCommandIdentity(
            executablePath: gitPath,
            arguments: [
                "--no-replace-objects", "-C", sourceRoot.path,
                "ls-tree", "-r", "-z", "--long", "--full-tree", sourceCommit.value,
            ],
            workingDirectory: sourceRoot.path,
            purpose: "snapshot committed documentation input names"
        )
        let treeResult = try runSnapshotCommand(
            treeCommand,
            standardInput: nil,
            maximumOutputBytes: ReleaseQualificationLimits.maximumOutputBytes,
            observations: &observations,
            cancellation: cancellation
        )
        let entries = try parseDocumentationTree(treeResult.standardOutput)
        let selected = entries.filter {
            Self.documentationSnapshotPaths.contains($0.path) ||
                ($0.path.hasPrefix("docs/") &&
                    ($0.path.hasSuffix(".md") || $0.path.hasSuffix(".mdx"))) ||
                ($0.path.hasPrefix("examples/") && $0.path.hasSuffix("/hostwright.yaml"))
        }
        guard Self.documentationSnapshotPaths.isSubset(of: Set(selected.map(\.path))) else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        var objectSizes: [String: Int] = [:]
        for entry in selected {
            if let existing = objectSizes[entry.objectID] {
                guard existing == entry.size else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
            } else {
                objectSizes[entry.objectID] = entry.size
            }
        }
        let objectGroups = try partitionDocumentationObjects(objectSizes)
        var blobs: [String: Data] = [:]
        for objectIDs in objectGroups {
            let batchInput = Data((objectIDs.joined(separator: "\n") + "\n").utf8)
            let batchCommand = try ReleaseQualificationCommandIdentity(
                executablePath: gitPath,
                arguments: [
                    "--no-replace-objects", "-C", sourceRoot.path,
                    "cat-file", "--batch",
                ],
                workingDirectory: sourceRoot.path,
                purpose: batchPurpose(
                    "snapshot committed documentation input bytes",
                    request: batchInput
                )
            )
            let batchResult = try runSnapshotCommand(
                batchCommand,
                standardInput: batchInput,
                maximumOutputBytes: ReleaseQualificationLimits.maximumOutputBytes,
                observations: &observations,
                cancellation: cancellation
            )
            let group = try parseDocumentationBlobs(
                batchResult.standardOutput,
                expectedObjectIDs: objectIDs
            )
            for (objectID, blob) in group {
                guard blobs.updateValue(blob, forKey: objectID) == nil else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
            }
        }
        var files: [String: String] = [:]
        var totalBytes = 0
        for entry in selected {
            guard let blob = blobs[entry.objectID], blob.count == entry.size else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            totalBytes += blob.count
            guard totalBytes <= ReleaseQualificationLimits.maximumSourceScanBytes else {
                throw ReleaseQualificationContractError.oversizedInput
            }
            files[entry.path] = blob.base64EncodedString()
        }
        let object: [String: Any] = [
            "entries": entries.map(\.path).sorted(),
            "files": files,
            "sourceCommit": sourceCommit.value,
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= ReleaseQualificationLimits.maximumSourceScanBytes else {
            throw ReleaseQualificationContractError.oversizedInput
        }
        return data
    }

    private func runSnapshotCommand(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        maximumOutputBytes: Int,
        observations: inout [ReleaseQualificationCommandObservation],
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        let startedAt = ReleaseQualificationTimestamp()
        let limits = try ReleaseQualificationCommandLimits(
            timeoutMilliseconds: commandLimits.timeoutMilliseconds,
            maximumStandardOutputBytes: maximumOutputBytes,
            maximumStandardErrorBytes: commandLimits.maximumStandardErrorBytes
        )
        let result = try sourceSnapshotRunner.run(
            command,
            standardInput: standardInput,
            limits: limits,
            cancellation: cancellation
        )
        observations.append(
            ReleaseQualificationCommandObservation(
                identity: command,
                startedAt: startedAt,
                endedAt: ReleaseQualificationTimestamp(),
                durationMilliseconds: result.durationMilliseconds,
                exitStatus: result.exitStatus,
                standardOutputSHA256: ReleaseQualificationHash.sha256(
                    data: result.standardOutput
                ),
                standardErrorSHA256: ReleaseQualificationHash.sha256(
                    data: result.standardError
                ),
                standardOutputBytes: result.standardOutput.count,
                standardErrorBytes: result.standardError.count,
                standardOutputTruncated: result.standardOutputTruncated,
                standardErrorTruncated: result.standardErrorTruncated
            )
        )
        guard result.exitStatus == 0,
              !result.standardOutputTruncated,
              !result.standardErrorTruncated else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        return result
    }

    private func parseDocumentationTree(_ data: Data) throws -> [DocumentationTreeEntry] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        guard !records.isEmpty, records.count <= 4_096 else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        var entries: [DocumentationTreeEntry] = []
        entries.reserveCapacity(records.count)
        for record in records {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")),
                  let metadata = String(data: record[..<tab], encoding: .utf8),
                  let path = String(data: record[record.index(after: tab)...], encoding: .utf8),
                  ReleaseQualificationPath.isSafeRelative(path) else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            let fields = metadata.split(whereSeparator: { $0 == " " })
            guard fields.count == 4,
                  fields[0] == "100644" || fields[0] == "100755",
                  fields[1] == "blob",
                  fields[2].range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                  let size = Int(fields[3]),
                  (0...ReleaseQualificationLimits.maximumSourceFileBytes).contains(size) else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            entries.append(
                DocumentationTreeEntry(path: path, objectID: String(fields[2]), size: size)
            )
        }
        guard entries.map(\.path).count == Set(entries.map(\.path)).count else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func parseSafeCheckTree(_ data: Data) throws -> SafeCheckTree {
        if data.isEmpty {
            return SafeCheckTree(regularEntries: [], nonRegularPaths: [])
        }
        guard data.last == 0 else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        let records = data.dropLast().split(
            separator: 0,
            omittingEmptySubsequences: false
        )
        guard !records.isEmpty,
              records.count <= 4_096,
              records.allSatisfy({ !$0.isEmpty }) else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        var seenPaths: Set<String> = []
        var regularEntries: [DocumentationTreeEntry] = []
        var nonRegularPaths: [String] = []
        regularEntries.reserveCapacity(records.count)
        for record in records {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")),
                  let metadata = String(data: record[..<tab], encoding: .utf8),
                  let path = String(data: record[record.index(after: tab)...], encoding: .utf8),
                  ReleaseQualificationPath.isSafeRelative(path),
                  seenPaths.insert(path).inserted else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            let fields = metadata.split(whereSeparator: { $0 == " " })
            guard fields.count == 4,
                  fields[2].range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            switch (fields[0], fields[1]) {
            case ("100644", "blob"), ("100755", "blob"):
                guard let size = Int(fields[3]),
                      (0...ReleaseQualificationLimits.maximumSourceFileBytes).contains(size) else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
                regularEntries.append(
                    DocumentationTreeEntry(
                        path: path,
                        objectID: String(fields[2]),
                        size: size
                    )
                )
            case ("120000", "blob"):
                guard let size = Int(fields[3]),
                      (0...ReleaseQualificationLimits.maximumSourceFileBytes).contains(size) else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
                nonRegularPaths.append(path)
            case ("160000", "commit"):
                guard fields[3] == "-" else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
                nonRegularPaths.append(path)
            default:
                throw ReleaseQualificationContractError.tamperedEvidence
            }
        }
        return SafeCheckTree(
            regularEntries: regularEntries.sorted { $0.path < $1.path },
            nonRegularPaths: nonRegularPaths.sorted()
        )
    }

    private func parseDocumentationBlobs(
        _ data: Data,
        expectedObjectIDs: [String]
    ) throws -> [String: Data] {
        var cursor = data.startIndex
        var blobs: [String: Data] = [:]
        for expectedObjectID in expectedObjectIDs {
            guard let newline = data[cursor...].firstIndex(of: UInt8(ascii: "\n")),
                  let header = String(data: data[cursor..<newline], encoding: .utf8) else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            let fields = header.split(whereSeparator: { $0 == " " })
            guard fields.count == 3,
                  fields[0] == Substring(expectedObjectID),
                  fields[1] == "blob",
                  let size = Int(fields[2]),
                  (0...ReleaseQualificationLimits.maximumSourceFileBytes).contains(size) else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            let start = data.index(after: newline)
            guard let end = data.index(start, offsetBy: size, limitedBy: data.endIndex),
                  end < data.endIndex,
                  data[end] == UInt8(ascii: "\n") else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            blobs[expectedObjectID] = Data(data[start..<end])
            cursor = data.index(after: end)
        }
        guard cursor == data.endIndex else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        return blobs
    }

    private func partitionDocumentationObjects(
        _ objectSizes: [String: Int]
    ) throws -> [[String]] {
        let maximumBatchBytes = 768 * 1_024
        var groups: [[String]] = []
        var current: [String] = []
        var currentBytes = 0
        for objectID in objectSizes.keys.sorted() {
            guard let size = objectSizes[objectID] else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            let framedBytes = size + objectID.utf8.count + 64
            guard framedBytes <= maximumBatchBytes else {
                throw ReleaseQualificationContractError.oversizedInput
            }
            if !current.isEmpty, currentBytes + framedBytes > maximumBatchBytes {
                groups.append(current)
                current = []
                currentBytes = 0
            }
            current.append(objectID)
            currentBytes += framedBytes
        }
        if !current.isEmpty { groups.append(current) }
        guard !groups.isEmpty,
              groups.count + 4 <= ReleaseQualificationLimits.maximumCommandCount else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        return groups
    }

    private func batchPurpose(_ base: String, request: Data) -> String {
        "\(base) request-sha256=\(ReleaseQualificationHash.sha256(data: request).value)"
    }

    private func validated(
        _ execution: ReleaseQualificationLaneExecution
    ) throws -> ReleaseQualificationLaneExecution {
        try execution.validate()
        return execution
    }

    private func unavailableDocumentationExecution(
        laneID: String
    ) throws -> ReleaseQualificationLaneExecution {
        try validated(
            ReleaseQualificationLaneExecution(
                laneID: laneID,
                status: .blocked,
                commands: [],
                blockers: [
                    ReleaseQualificationBlocker(
                        reason: .dependencyUnavailable,
                        field: "registry.\(laneID).provider",
                        detail: "a trusted bounded Python provider is unavailable"
                    )
                ],
                failures: []
            )
        )
    }

    private func blockedDocumentationExecution(
        laneID: String,
        reason: ReleaseQualificationUnsupportedReason,
        detail: String
    ) throws -> ReleaseQualificationLaneExecution {
        try validated(
            ReleaseQualificationLaneExecution(
                laneID: laneID,
                status: .blocked,
                commands: [],
                blockers: [
                    ReleaseQualificationBlocker(
                        reason: reason,
                        field: "registry.\(laneID).provider",
                        detail: detail
                    )
                ],
                failures: []
            )
        )
    }

    private func blockedLocalExecution(
        laneID: String,
        reason: ReleaseQualificationUnsupportedReason,
        detail: String,
        commands: [ReleaseQualificationCommandObservation] = []
    ) throws -> ReleaseQualificationLaneExecution {
        try validated(
            ReleaseQualificationLaneExecution(
                laneID: laneID,
                status: .blocked,
                commands: commands,
                blockers: [
                    ReleaseQualificationBlocker(
                        reason: reason,
                        field: "registry.\(laneID).provider",
                        detail: detail
                    )
                ],
                failures: []
            )
        )
    }
}

public struct ReleaseQualificationSafeCheckRunner: Sendable {
    public init() {}

    public func run(
        sourceRoot: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> [ReleaseQualificationSafeCheckResult] {
        guard ReleaseQualificationPath.isNormalizedAbsolute(sourceRoot.path),
              try ReleaseQualificationFile.isDirectory(sourceRoot) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        try checkCancellation(cancellation)
        let results = [
            try dependencyLockIntegrity(sourceRoot: sourceRoot, cancellation: cancellation),
            try boundedSecretScan(sourceRoot: sourceRoot, cancellation: cancellation)
        ]
        for result in results { try result.validate() }
        return results
    }

    func run(
        checkID: String,
        immutableFiles: [String: Data],
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ReleaseQualificationSafeCheckResult {
        try checkCancellation(cancellation)
        guard checkID == "dependency-lock-integrity" ||
                checkID == "license-policy" ||
                checkID == "secret-scan" else {
            throw ReleaseQualificationContractError.invalid(
                field: "safeCheck.checkID",
                reason: "no immutable safe-check provider is wired for this identity"
            )
        }
        guard !immutableFiles.isEmpty, immutableFiles.count <= 4_096 else {
            let unavailableReason: ReleaseQualificationUnsupportedReason
            switch checkID {
            case "license-policy": unavailableReason = .licenseMetadataUnavailable
            case "secret-scan": unavailableReason = .secretScanUnavailable
            default: unavailableReason = .dependencyUnavailable
            }
            return blockedImmutableCheck(
                checkID: checkID,
                reason: unavailableReason,
                field: "sourceCommit",
                detail: "the exact committed safe-check input is unavailable"
            )
        }
        var scannedBytes = 0
        for (path, data) in immutableFiles {
            guard ReleaseQualificationPath.isSafeRelative(path),
                  data.count <= ReleaseQualificationLimits.maximumSourceFileBytes,
                  scannedBytes <= ReleaseQualificationLimits.maximumSourceScanBytes - data.count else {
                return blockedImmutableCheck(
                    checkID: checkID,
                    reason: .outputLimitExceeded,
                    field: "sourceCommit",
                    detail: "the exact committed safe-check input exceeds its bounded source budget",
                    scannedBytes: scannedBytes
                )
            }
            scannedBytes += data.count
        }

        let result: ReleaseQualificationSafeCheckResult
        switch checkID {
        case "dependency-lock-integrity":
            let required = Set(["Package.swift", "Package.resolved"])
            guard Set(immutableFiles.keys) == required,
                  let packageData = immutableFiles["Package.swift"],
                  let resolvedData = immutableFiles["Package.resolved"] else {
                return blockedImmutableCheck(
                    checkID: checkID,
                    reason: .dependencyUnavailable,
                    field: "sourceCommit",
                    detail: "Package.swift or Package.resolved is unavailable in the exact commit",
                    scannedBytes: scannedBytes
                )
            }
            guard let packageText = String(data: packageData, encoding: .utf8) else {
                return ReleaseQualificationSafeCheckResult(
                    checkID: checkID,
                    status: .failed,
                    scannedBytes: scannedBytes,
                    blockers: [],
                    failures: ["Package.swift is not valid UTF-8"]
                )
            }
            let failures = dependencyFailures(
                packageText: packageText,
                resolvedData: resolvedData
            )
            result = ReleaseQualificationSafeCheckResult(
                checkID: checkID,
                status: failures.isEmpty ? .passed : .failed,
                scannedBytes: scannedBytes,
                blockers: [],
                failures: failures
            )
        case "license-policy":
            result = licensePolicyIntegrity(
                immutableFiles: immutableFiles,
                scannedBytes: scannedBytes
            )
        case "secret-scan":
            for path in immutableFiles.keys {
                guard !path.split(separator: "/").contains(where: { component in
                    releaseQualificationSecretScanExcludedDirectories.contains(
                        String(component)
                    )
                }) else {
                    return blockedImmutableCheck(
                        checkID: checkID,
                        reason: .unsafePath,
                        field: "sourceCommit",
                        detail: "the exact committed secret-scan input contains an excluded path",
                        scannedBytes: scannedBytes
                    )
                }
            }
            var failures: [String] = []
            for path in immutableFiles.keys.sorted() {
                try checkCancellation(cancellation)
                guard let data = immutableFiles[path] else {
                    return blockedImmutableCheck(
                        checkID: checkID,
                        reason: .secretScanUnavailable,
                        field: "sourceCommit",
                        detail: "the exact committed secret-scan input is unavailable",
                        scannedBytes: scannedBytes
                    )
                }
                guard let labels = secretLabels(in: data) else {
                    return blockedImmutableCheck(
                        checkID: checkID,
                        reason: .secretScanUnavailable,
                        field: "sourceCommit",
                        detail: "the exact committed secret-scan input uses an unsupported byte encoding",
                        scannedBytes: scannedBytes
                    )
                }
                for label in labels.sorted() {
                    failures.append("high-confidence \(label) pattern in \(path)")
                }
            }
            result = ReleaseQualificationSafeCheckResult(
                checkID: checkID,
                status: failures.isEmpty ? .passed : .failed,
                scannedBytes: scannedBytes,
                blockers: [],
                failures: boundedSecretFailures(failures)
            )
        default:
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        try result.validate()
        return result
    }

    private func dependencyLockIntegrity(
        sourceRoot: URL,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationSafeCheckResult {
        try checkCancellation(cancellation)
        let package = sourceRoot.appendingPathComponent("Package.swift")
        let resolved = sourceRoot.appendingPathComponent("Package.resolved")
        guard try ReleaseQualificationFile.isRegularNonSymlink(package),
              try ReleaseQualificationFile.isRegularNonSymlink(resolved) else {
            return ReleaseQualificationSafeCheckResult(
                checkID: "dependency-lock-integrity",
                status: .blocked,
                scannedBytes: 0,
                blockers: [
                    ReleaseQualificationBlocker(
                        reason: .dependencyUnavailable,
                        field: "Package.resolved",
                        detail: "Package.swift or Package.resolved is unavailable"
                    )
                ],
                failures: []
            )
        }
        let packageData = try Data(contentsOf: package, options: .mappedIfSafe)
        let resolvedData = try Data(contentsOf: resolved, options: .mappedIfSafe)
        guard packageData.count <= ReleaseQualificationLimits.maximumSourceFileBytes,
              resolvedData.count <= ReleaseQualificationLimits.maximumSourceFileBytes,
              let packageText = String(data: packageData, encoding: .utf8) else {
            return ReleaseQualificationSafeCheckResult(
                checkID: "dependency-lock-integrity",
                status: .blocked,
                scannedBytes: packageData.count + resolvedData.count,
                blockers: [
                    ReleaseQualificationBlocker(
                        reason: .outputLimitExceeded,
                        field: "Package.swift",
                        detail: "dependency inputs exceed the bounded integrity-check limit"
                    )
                ],
                failures: []
            )
        }
        let failures = dependencyFailures(
            packageText: packageText,
            resolvedData: resolvedData
        )
        return ReleaseQualificationSafeCheckResult(
            checkID: "dependency-lock-integrity",
            status: failures.isEmpty ? .passed : .failed,
            scannedBytes: packageData.count + resolvedData.count,
            blockers: [],
            failures: failures
        )
    }

    private func dependencyFailures(
        packageText: String,
        resolvedData: Data
    ) -> [String] {
        let directPins = canonicalDirectPins()
        var failures: [String] = []
        guard hasCanonicalDirectDependencies(packageText, directPins: directPins) else {
            failures.append(
                "Package.swift direct dependencies are not exactly the canonical four exact pins"
            )
            return dependencyResolutionFailures(
                resolvedData: resolvedData,
                directPins: directPins,
                initialFailures: failures
            )
        }
        return dependencyResolutionFailures(
            resolvedData: resolvedData,
            directPins: directPins,
            initialFailures: failures
        )
    }

    private typealias DirectPin = (
        identity: String,
        version: String,
        location: String,
        revision: String
    )

    private func canonicalDirectPins() -> [DirectPin] {
        [
            (
                "containerization",
                "0.35.0",
                "https://github.com/apple/containerization.git",
                "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b"
            ),
            (
                "yams",
                "6.2.2",
                "https://github.com/jpsim/Yams.git",
                "a27b21e0c81c5bf42049b897a62aaf387e80f279"
            ),
            (
                "swift-certificates",
                "1.19.3",
                "https://github.com/apple/swift-certificates.git",
                "89fbc3714264cce8db8e4ec51b64e01c3e28c6c5"
            ),
            (
                "wasmkit",
                "0.3.1",
                "https://github.com/swiftwasm/WasmKit.git",
                "ee36070acc31878ef727b90d5bdc4c9cc1fff22e"
            )
        ]
    }

    private func licensePolicyIntegrity(
        immutableFiles: [String: Data],
        scannedBytes: Int
    ) -> ReleaseQualificationSafeCheckResult {
        let policyPath = ReleaseQualificationLicensePolicy.relativePath
        guard let packageData = immutableFiles["Package.swift"],
              let resolvedData = immutableFiles["Package.resolved"],
              let policyData = immutableFiles[policyPath] else {
            return blockedImmutableCheck(
                checkID: "license-policy",
                reason: .licenseMetadataUnavailable,
                field: policyPath,
                detail: "the exact committed license-policy receipt or direct-pin input is unavailable",
                scannedBytes: scannedBytes
            )
        }
        guard policyData.count <= ReleaseQualificationLicensePolicy.maximumPolicyBytes else {
            return blockedImmutableCheck(
                checkID: "license-policy",
                reason: .outputLimitExceeded,
                field: policyPath,
                detail: "the committed license-policy receipt exceeds its bounded size",
                scannedBytes: scannedBytes
            )
        }
        guard let packageText = String(data: packageData, encoding: .utf8),
              dependencyFailures(
                  packageText: packageText,
                  resolvedData: resolvedData
              ).isEmpty else {
            return failedImmutableCheck(
                checkID: "license-policy",
                scannedBytes: scannedBytes,
                failures: [
                    "license policy cannot bind because the exact direct dependency pins are invalid"
                ]
            )
        }

        let policy: ReleaseQualificationLicensePolicy
        do {
            policy = try ReleaseQualificationJSON.decode(
                ReleaseQualificationLicensePolicy.self,
                from: policyData
            )
        } catch {
            return failedImmutableCheck(
                checkID: "license-policy",
                scannedBytes: scannedBytes,
                failures: [
                    "license policy is malformed or non-canonical at \(policyPath)"
                ]
            )
        }

        let directPins = canonicalDirectPins()
        let expectedByIdentity = Dictionary(
            uniqueKeysWithValues: directPins.map { ($0.identity, $0) }
        )
        let expectedIdentities = Set(expectedByIdentity.keys)
        let actualIdentities = Set(policy.entries.map(\.identity))
        let missingIdentities = expectedIdentities.subtracting(actualIdentities).sorted()
        if !missingIdentities.isEmpty {
            return blockedImmutableCheck(
                checkID: "license-policy",
                reason: .licenseMetadataUnavailable,
                field: policyPath,
                detail: "committed license-policy receipts are missing for identities: " +
                    missingIdentities.joined(separator: ", "),
                scannedBytes: scannedBytes
            )
        }

        var failures: [String] = []
        for identity in actualIdentities.subtracting(expectedIdentities).sorted() {
            failures.append("license policy has an unexpected direct receipt for \(identity)")
        }
        for entry in policy.entries {
            guard let pin = expectedByIdentity[entry.identity] else { continue }
            if entry.location != pin.location {
                failures.append(
                    "license policy receipt \(entry.identity) does not match the direct pin location"
                )
            }
            if entry.version != pin.version {
                failures.append(
                    "license policy receipt \(entry.identity) does not match the direct pin version"
                )
            }
            if entry.revision != pin.revision {
                failures.append(
                    "license policy receipt \(entry.identity) does not match the direct pin revision"
                )
            }
        }

        let receiptPaths = Set(policy.entries.map(\.licenseTextPath))
        let committedLicensePaths = Set(immutableFiles.keys.filter {
            $0.hasPrefix(ReleaseQualificationLicensePolicy.licenseTextPrefix)
        })
        for path in committedLicensePaths.subtracting(receiptPaths).sorted() {
            failures.append("license policy has an unreferenced committed text at \(path)")
        }
        if !failures.isEmpty {
            return failedImmutableCheck(
                checkID: "license-policy",
                scannedBytes: scannedBytes,
                failures: failures
            )
        }

        for entry in policy.entries {
            guard let text = immutableFiles[entry.licenseTextPath] else {
                return blockedImmutableCheck(
                    checkID: "license-policy",
                    reason: .licenseMetadataUnavailable,
                    field: entry.licenseTextPath,
                    detail: "committed license text is unavailable for \(entry.identity) at \(entry.licenseTextPath)",
                    scannedBytes: scannedBytes
                )
            }
            if text.count != entry.licenseTextSizeBytes {
                failures.append(
                    "license text size does not match for \(entry.identity) at \(entry.licenseTextPath)"
                )
            }
            if ReleaseQualificationHash.sha256(data: text) != entry.licenseTextSHA256 {
                failures.append(
                    "license text SHA-256 does not match for \(entry.identity) at \(entry.licenseTextPath)"
                )
            }
        }
        return failures.isEmpty
            ? ReleaseQualificationSafeCheckResult(
                checkID: "license-policy",
                status: .passed,
                scannedBytes: scannedBytes,
                blockers: [],
                failures: []
            )
            : failedImmutableCheck(
                checkID: "license-policy",
                scannedBytes: scannedBytes,
                failures: failures
            )
    }

    private enum PackageManifestToken: Equatable {
        case identifier(String)
        case string(String)
        case symbol(UInt8)
    }

    private func hasCanonicalDirectDependencies(
        _ packageText: String,
        directPins: [DirectPin]
    ) -> Bool {
        guard let tokens = lexPackageManifest(packageText) else { return false }
        let prefix: [PackageManifestToken] = [
            .identifier("let"), .identifier("package"), .symbol(61),
            .identifier("Package"), .symbol(40),
        ]
        let starts = tokens.indices.filter { index in
            guard index + prefix.count <= tokens.count else { return false }
            return Array(tokens[index..<(index + prefix.count)]) == prefix
        }
        guard starts.count == 1 else { return false }
        let start = starts[0] + prefix.count
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var dependencyRanges: [Range<Int>] = []
        var index = start
        while index < tokens.count {
            if tokens[index] == .symbol(41) {
                if parenthesisDepth == 0 { break }
                parenthesisDepth -= 1
            } else if tokens[index] == .symbol(40) {
                parenthesisDepth += 1
            } else if tokens[index] == .symbol(91) {
                bracketDepth += 1
            } else if tokens[index] == .symbol(93) {
                guard bracketDepth > 0 else { return false }
                bracketDepth -= 1
            } else if tokens[index] == .symbol(123) {
                braceDepth += 1
            } else if tokens[index] == .symbol(125) {
                guard braceDepth > 0 else { return false }
                braceDepth -= 1
            } else if parenthesisDepth == 0,
                      bracketDepth == 0,
                      braceDepth == 0,
                      tokens[index] == .identifier("dependencies"),
                      index + 2 < tokens.count,
                      tokens[index + 1] == .symbol(58),
                      tokens[index + 2] == .symbol(91),
                      let end = matchingBracket(in: tokens, openingAt: index + 2) {
                dependencyRanges.append((index + 2)..<(end + 1))
                index = end
            }
            index += 1
        }
        guard dependencyRanges.count == 1 else { return false }
        let packageCallCount = tokens.indices.filter { index in
            index + 2 < tokens.count &&
                tokens[index] == .symbol(46) &&
                tokens[index + 1] == .identifier("package") &&
                tokens[index + 2] == .symbol(40)
        }.count
        return packageCallCount == directPins.count &&
            Array(tokens[dependencyRanges[0]]) == canonicalDependencyTokens(directPins)
    }

    private func canonicalDependencyTokens(
        _ directPins: [DirectPin]
    ) -> [PackageManifestToken] {
        var tokens: [PackageManifestToken] = [.symbol(91)]
        for (index, pin) in directPins.enumerated() {
            tokens += [
                .symbol(46), .identifier("package"), .symbol(40),
                .identifier("url"), .symbol(58), .string(pin.location), .symbol(44),
                .identifier("exact"), .symbol(58), .string(pin.version),
                .symbol(41),
            ]
            if index < directPins.count - 1 { tokens.append(.symbol(44)) }
        }
        tokens.append(.symbol(93))
        return tokens
    }

    private func matchingBracket(
        in tokens: [PackageManifestToken],
        openingAt start: Int
    ) -> Int? {
        var depth = 0
        for index in start..<tokens.count {
            if tokens[index] == .symbol(91) {
                depth += 1
            } else if tokens[index] == .symbol(93) {
                depth -= 1
                if depth == 0 { return index }
                if depth < 0 { return nil }
            }
        }
        return nil
    }

    private func lexPackageManifest(_ text: String) -> [PackageManifestToken]? {
        let bytes = Array(text.utf8)
        var tokens: [PackageManifestToken] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 9 || byte == 10 || byte == 13 || byte == 32 {
                index += 1
                continue
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                index += 2
                while index < bytes.count, bytes[index] != 10 { index += 1 }
                continue
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
                index += 2
                var depth = 1
                while index < bytes.count, depth > 0 {
                    if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 42 {
                        depth += 1
                        index += 2
                    } else if index + 1 < bytes.count,
                              bytes[index] == 42,
                              bytes[index + 1] == 47 {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                }
                guard depth == 0 else { return nil }
                continue
            }
            if byte == 34 {
                guard !(index + 2 < bytes.count &&
                        bytes[index + 1] == 34 && bytes[index + 2] == 34) else {
                    return nil
                }
                index += 1
                var value: [UInt8] = []
                var closed = false
                while index < bytes.count {
                    let stringByte = bytes[index]
                    if stringByte == 34 {
                        closed = true
                        index += 1
                        break
                    }
                    guard stringByte != 10, stringByte != 13 else { return nil }
                    if stringByte == 92 {
                        guard index + 1 < bytes.count else { return nil }
                        value.append(stringByte)
                        value.append(bytes[index + 1])
                        index += 2
                    } else {
                        value.append(stringByte)
                        index += 1
                    }
                }
                guard closed, let string = String(bytes: value, encoding: .utf8) else {
                    return nil
                }
                tokens.append(.string(string))
            } else if isManifestIdentifierStart(byte) {
                let start = index
                index += 1
                while index < bytes.count, isManifestIdentifierContinuation(bytes[index]) {
                    index += 1
                }
                guard let identifier = String(bytes: bytes[start..<index], encoding: .utf8) else {
                    return nil
                }
                tokens.append(.identifier(identifier))
            } else {
                guard byte >= 0x20, byte < 0x7f else { return nil }
                tokens.append(.symbol(byte))
                index += 1
            }
            guard tokens.count <= 32_768 else { return nil }
        }
        return tokens
    }

    private func isManifestIdentifierStart(_ byte: UInt8) -> Bool {
        byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private func isManifestIdentifierContinuation(_ byte: UInt8) -> Bool {
        isManifestIdentifierStart(byte) || (48...57).contains(byte)
    }

    private func dependencyResolutionFailures(
        resolvedData: Data,
        directPins: [DirectPin],
        initialFailures: [String]
    ) -> [String] {
        var failures = initialFailures
        do {
            let object = try JSONSerialization.jsonObject(with: resolvedData)
            guard let root = object as? [String: Any],
                  Set(root.keys) == Set(["originHash", "pins", "version"]),
                  let resolvedSchemaVersion = root["version"] as? Int,
                  resolvedSchemaVersion == 3,
                  let originHash = root["originHash"] as? String,
                  originHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let pins = root["pins"] as? [[String: Any]],
                  pins.count <= ReleaseQualificationLimits.maximumToolFacts else {
                return failures + ["Package.resolved has malformed origin or pin data"]
            }
            var seen: Set<String> = []
            for pin in pins {
                guard Set(pin.keys) == Set(["identity", "kind", "location", "state"]),
                      pin["kind"] as? String == "remoteSourceControl",
                      let identity = pin["identity"] as? String,
                      seen.insert(identity).inserted,
                      let location = pin["location"] as? String,
                      let state = pin["state"] as? [String: Any],
                      Set(state.keys) == Set(["revision", "version"]),
                      let revision = state["revision"] as? String,
                      revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                      let version = state["version"] as? String,
                      (try? ReleaseQualificationSemanticVersion(
                          parsing: version,
                          allowingTwoComponents: true
                      )) != nil else {
                    failures.append("Package.resolved contains malformed or duplicate pin data")
                    continue
                }
                if let expected = directPins.first(where: { $0.0 == identity }) {
                    if location != expected.2 {
                        failures.append("Package.resolved direct pin \(identity) has an unexpected location")
                    }
                    if version != expected.1 {
                        failures.append("Package.resolved direct pin \(identity) is \(version), expected \(expected.1)")
                    }
                    if revision != expected.3 {
                        failures.append("Package.resolved direct pin \(identity) has an unexpected revision")
                    }
                }
            }
            for expected in directPins where !seen.contains(expected.0) {
                failures.append("Package.resolved is missing direct pin \(expected.0)")
            }
        } catch {
            failures.append("Package.resolved is not valid JSON")
        }
        return Array(Set(failures)).sorted()
    }

    private func boundedSecretScan(
        sourceRoot: URL,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationSafeCheckResult {
        try checkCancellation(cancellation)
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsPackageDescendants]
        ) else {
            return ReleaseQualificationSafeCheckResult(
                checkID: "secret-scan",
                status: .blocked,
                scannedBytes: 0,
                blockers: [
                    ReleaseQualificationBlocker(
                        reason: .secretScanUnavailable,
                        field: "sourceRoot",
                        detail: "source tree could not be enumerated safely"
                    )
                ],
                failures: []
            )
        }
        let excludedDirectories: Set<String> = [
            ".git", ".build", ".swiftpm", ".codex", ".claude", "tmp"
        ]
        var scannedBytes = 0
        var failures: [String] = []
        for case let url as URL in enumerator {
            try checkCancellation(cancellation)
            guard ReleaseQualificationPath.isContained(url, in: sourceRoot) else {
                return blockedSecretScan(
                    scannedBytes: scannedBytes,
                    reason: .unsafePath,
                    detail: "enumerator produced a path outside the source root"
                )
            }
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                return blockedSecretScan(
                    scannedBytes: scannedBytes,
                    reason: .unsafePath,
                    detail: "secret scan encountered a symbolic link"
                )
            }
            if values.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.fileSize ?? -1 >= 0 else { continue }
            let size = values.fileSize ?? 0
            guard size <= ReleaseQualificationLimits.maximumSourceFileBytes,
                  scannedBytes <= ReleaseQualificationLimits.maximumSourceScanBytes - size else {
                return blockedSecretScan(
                    scannedBytes: scannedBytes,
                    reason: .outputLimitExceeded,
                    detail: "secret scan exceeded its bounded source budget"
                )
            }
            guard try ReleaseQualificationFile.isRegularNonSymlink(url) else {
                continue
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            scannedBytes += data.count
            let relative = String(
                url.path.dropFirst(sourceRoot.path.count + 1)
            )
            guard let labels = secretLabels(in: data) else {
                return blockedSecretScan(
                    scannedBytes: scannedBytes,
                    reason: .secretScanUnavailable,
                    detail: "secret scan encountered an unsupported byte encoding"
                )
            }
            for label in labels.sorted() {
                failures.append("high-confidence \(label) pattern in \(relative)")
            }
        }
        return ReleaseQualificationSafeCheckResult(
            checkID: "secret-scan",
            status: failures.isEmpty ? .passed : .failed,
            scannedBytes: scannedBytes,
            blockers: [],
            failures: boundedSecretFailures(failures)
        )
    }

    private static let privateKeyPrefixes: [[UInt8]] = [
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN DSA PRIVATE KEY-----",
        "-----BEGIN PGP PRIVATE KEY-----",
    ].map { Array($0.utf8) }

    private static let awsAccessKeyPrefix = Array("AKIA".utf8)
    private static let gitHubTokenPrefixes = ["ghp_", "github_pat_"].map {
        Array($0.utf8)
    }
    private static let slackTokenPrefixes = ["xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-"].map {
        Array($0.utf8)
    }
    private static let apiKeyPrefix = Array("sk-".utf8)

    private func secretLabels(in data: Data) -> Set<String>? {
        guard let views = secretScanViews(for: data) else { return nil }
        var labels: Set<String> = []
        for bytes in views {
            labels.formUnion(secretLabels(in: bytes))
        }
        return labels
    }

    private func secretScanViews(for data: Data) -> [[UInt8]]? {
        let bytes = Array(data)
        if hasPrefix([0xff, 0xfe, 0x00, 0x00], in: bytes, at: 0) ||
            hasPrefix([0x00, 0x00, 0xfe, 0xff], in: bytes, at: 0) ||
            hasPrefix([0x00, 0x00, 0xff, 0xfe], in: bytes, at: 0) ||
            hasPrefix([0xfe, 0xff, 0x00, 0x00], in: bytes, at: 0) {
            return nil
        }
        let isLittleEndianUTF16 = hasPrefix([0xff, 0xfe], in: bytes, at: 0)
        let isBigEndianUTF16 = hasPrefix([0xfe, 0xff], in: bytes, at: 0)
        guard isLittleEndianUTF16 || isBigEndianUTF16 else { return [bytes] }
        guard (bytes.count - 2).isMultiple(of: 2) else { return nil }

        var decodedASCII: [UInt8] = []
        decodedASCII.reserveCapacity((bytes.count - 2) / 2)
        var index = 2
        while index < bytes.count {
            let codeUnit: UInt16
            if isLittleEndianUTF16 {
                codeUnit = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            } else {
                codeUnit = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
            }
            decodedASCII.append(codeUnit <= 0x7f ? UInt8(codeUnit) : 0)
            index += 2
        }
        return [bytes, decodedASCII]
    }

    private func secretLabels(in bytes: [UInt8]) -> Set<String> {
        var labels: Set<String> = []
        for index in bytes.indices {
            if !labels.contains("private-key"),
               Self.privateKeyPrefixes.contains(where: {
                   hasPrefix($0, in: bytes, at: index)
               }) {
                labels.insert("private-key")
            }
            if !labels.contains("AWS-access-key"),
               hasPrefix(Self.awsAccessKeyPrefix, in: bytes, at: index),
               hasRun(
                   in: bytes,
                   after: index + Self.awsAccessKeyPrefix.count,
                   minimumCount: 16,
                   allowed: isUppercaseLetterOrDigit
               ) {
                labels.insert("AWS-access-key")
            }
            if !labels.contains("GitHub-token"),
               Self.gitHubTokenPrefixes.contains(where: { prefix in
                   hasPrefix(prefix, in: bytes, at: index) &&
                       hasRun(
                           in: bytes,
                           after: index + prefix.count,
                           minimumCount: 20,
                           allowed: isLetterDigitOrUnderscore
                       )
               }) {
                labels.insert("GitHub-token")
            }
            if !labels.contains("Slack-token"),
               Self.slackTokenPrefixes.contains(where: { prefix in
                   hasPrefix(prefix, in: bytes, at: index) &&
                       hasRun(
                           in: bytes,
                           after: index + prefix.count,
                           minimumCount: 20,
                           allowed: isLetterDigitOrHyphen
                       )
               }) {
                labels.insert("Slack-token")
            }
            if !labels.contains("API-key"),
               hasPrefix(Self.apiKeyPrefix, in: bytes, at: index),
               hasRun(
                   in: bytes,
                   after: index + Self.apiKeyPrefix.count,
                   minimumCount: 20,
                   allowed: isLetterOrDigit
               ) {
                labels.insert("API-key")
            }
            if labels.count == 5 { break }
        }
        return labels
    }

    private func hasPrefix(
        _ prefix: [UInt8],
        in bytes: [UInt8],
        at start: Int
    ) -> Bool {
        guard start >= 0,
              prefix.count <= bytes.count,
              start <= bytes.count - prefix.count else {
            return false
        }
        return bytes[start..<(start + prefix.count)].elementsEqual(prefix)
    }

    private func hasRun(
        in bytes: [UInt8],
        after start: Int,
        minimumCount: Int,
        allowed: (UInt8) -> Bool
    ) -> Bool {
        guard start >= 0,
              minimumCount <= bytes.count,
              start <= bytes.count - minimumCount else {
            return false
        }
        return bytes[start..<(start + minimumCount)].allSatisfy(allowed)
    }

    private func isUppercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte)
    }

    private func isLetterOrDigit(_ byte: UInt8) -> Bool {
        isUppercaseLetterOrDigit(byte) || (97...122).contains(byte)
    }

    private func isLetterDigitOrUnderscore(_ byte: UInt8) -> Bool {
        isLetterOrDigit(byte) || byte == 95
    }

    private func isLetterDigitOrHyphen(_ byte: UInt8) -> Bool {
        isLetterOrDigit(byte) || byte == 45
    }

    private func boundedSecretFailures(_ failures: [String]) -> [String] {
        let unique = Array(Set(failures)).sorted()
        return Array(unique.prefix(ReleaseQualificationLimits.maximumBlockers))
    }

    private func blockedImmutableCheck(
        checkID: String,
        reason: ReleaseQualificationUnsupportedReason,
        field: String,
        detail: String,
        scannedBytes: Int = 0
    ) -> ReleaseQualificationSafeCheckResult {
        ReleaseQualificationSafeCheckResult(
            checkID: checkID,
            status: .blocked,
            scannedBytes: scannedBytes,
            blockers: [
                ReleaseQualificationBlocker(
                    reason: reason,
                    field: field,
                    detail: detail
                )
            ],
            failures: []
        )
    }

    private func failedImmutableCheck(
        checkID: String,
        scannedBytes: Int,
        failures: [String]
    ) -> ReleaseQualificationSafeCheckResult {
        let bounded = Array(
            Array(Set(failures)).sorted().prefix(ReleaseQualificationLimits.maximumBlockers)
        )
        return ReleaseQualificationSafeCheckResult(
            checkID: checkID,
            status: .failed,
            scannedBytes: scannedBytes,
            blockers: [],
            failures: bounded
        )
    }

    private func blockedSecretScan(
        scannedBytes: Int,
        reason: ReleaseQualificationUnsupportedReason,
        detail: String
    ) -> ReleaseQualificationSafeCheckResult {
        ReleaseQualificationSafeCheckResult(
            checkID: "secret-scan",
            status: .blocked,
            scannedBytes: scannedBytes,
            blockers: [
                ReleaseQualificationBlocker(
                    reason: reason,
                    field: "sourceRoot",
                    detail: detail
                )
            ],
            failures: []
        )
    }

    private func checkCancellation(_ cancellation: SecureSubprocessCancellation) throws {
        guard !cancellation.isCancelled else {
            throw ReleaseQualificationContractError.cancelled
        }
    }
}

public enum ReleaseQualificationSafeCheckAggregation {
    public static func status(
        _ results: [ReleaseQualificationSafeCheckResult]
    ) throws -> ReleaseQualificationOutcomeStatus {
        guard !results.isEmpty else {
            throw ReleaseQualificationContractError.invalid(
                field: "safeChecks",
                reason: "safe-check aggregation requires at least one result"
            )
        }
        for result in results { try result.validate() }
        if results.contains(where: { $0.status == .failed }) { return .failed }
        if results.contains(where: { $0.status == .blocked || $0.status == .unavailable }) {
            return .blocked
        }
        return .passed
    }
}

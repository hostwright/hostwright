import Foundation
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
        return ReleaseQualificationRegistry(lanes: [
            ReleaseQualificationLane(
                id: "dependency-lock-integrity",
                kind: .dependency,
                target: "Package.swift and Package.resolved exact direct-pin integrity",
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
                id: "license-metadata",
                kind: .license,
                target: "dependency license metadata inventory",
                executionMode: .safeLocal,
                authority: .local,
                requiredEvidenceClasses: [.securityAssessment],
                budget: localBudget,
                corpus: [],
                exclusions: [
                    "no license metadata provider is wired in this slice"
                ]
            )
        ])
    }
}

public struct ReleaseQualificationRegistryPlanner: Sendable {
    public let registry: ReleaseQualificationRegistry

    public init(registry: ReleaseQualificationRegistry = ReleaseQualificationDefaultRegistry.registry) {
        self.registry = registry
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
        case .dependency, .secret:
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
            blockers.append(
                ReleaseQualificationBlocker(
                    reason: .licenseMetadataUnavailable,
                    field: "registry.\(lane.id).provider",
                    detail: "no authoritative dependency license metadata provider is wired"
                )
            )
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
        let directPins = [
            ("containerization", "0.35.0", "https://github.com/apple/containerization.git"),
            ("yams", "6.2.2", "https://github.com/jpsim/Yams.git"),
            ("swift-certificates", "1.19.3", "https://github.com/apple/swift-certificates.git"),
            ("wasmkit", "0.3.1", "https://github.com/swiftwasm/WasmKit.git")
        ]
        var failures: [String] = []
        for (identity, version, location) in directPins {
            if !packageText.contains("exact: \"\(version)\"") ||
                !packageText.contains("url: \"\(location)\"") {
                failures.append("Package.swift direct pin is not exact for \(identity)")
            }
        }
        do {
            let object = try JSONSerialization.jsonObject(with: resolvedData)
            guard let root = object as? [String: Any],
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
                guard let identity = pin["identity"] as? String,
                      seen.insert(identity).inserted,
                      let location = pin["location"] as? String,
                      let state = pin["state"] as? [String: Any],
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
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let relative = String(
                url.path.dropFirst(sourceRoot.path.count + 1)
            )
            for (label, pattern) in Self.secretPatterns {
                if text.range(of: pattern, options: .regularExpression) != nil {
                    failures.append("high-confidence \(label) pattern in \(relative)")
                }
            }
        }
        return ReleaseQualificationSafeCheckResult(
            checkID: "secret-scan",
            status: failures.isEmpty ? .passed : .failed,
            scannedBytes: scannedBytes,
            blockers: [],
            failures: Array(Set(failures)).sorted()
        )
    }

    private static let secretPatterns: [(String, String)] = [
        ("private-key", "-----BEGIN (RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY-----"),
        ("AWS-access-key", "AKIA[0-9A-Z]{16}"),
        ("GitHub-token", "(ghp|github_pat)_[A-Za-z0-9_]{20,}"),
        ("Slack-token", "xox[baprs]-[A-Za-z0-9-]{20,}"),
        ("API-key", "sk-[A-Za-z0-9]{20,}")
    ]

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

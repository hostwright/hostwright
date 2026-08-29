import Foundation
import XCTest
import HostwrightCore
@testable import HostwrightReleaseQualification

private struct ReleaseQualificationFixedCommandRunner:
    ReleaseQualificationStandardInputCommandRunning
{
    let result: ReleaseQualificationCommandResult

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        result
    }

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        result
    }
}

private struct ReleaseQualificationFixedPythonLocator: ReleaseQualificationPythonLocating {
    let path: String?

    func python3Path() -> String? {
        path
    }
}

private struct ReleaseQualificationSecondCommandTimeoutRunner:
    ReleaseQualificationStandardInputCommandRunning
{
    func run(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        try result(for: command)
    }

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        try result(for: command)
    }

    private func result(
        for command: ReleaseQualificationCommandIdentity
    ) throws -> ReleaseQualificationCommandResult {
        if command.arguments.contains(where: { $0.hasSuffix("check-current-truth.py") }) {
            throw ReleaseQualificationCommandError.timedOut
        }
        return ReleaseQualificationCommandResult(
            exitStatus: 0,
            standardOutput: Data("first validator passed".utf8),
            standardError: Data(),
            durationMilliseconds: 7
        )
    }
}

struct ReleaseQualificationMutatingSnapshotRunner:
    ReleaseQualificationStandardInputCommandRunning
{
    let sourceRoot: URL
    let replacement: Data

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        let result = try ReleaseQualificationSubprocessRunner().run(
            command,
            standardInput: standardInput,
            limits: limits,
            cancellation: cancellation
        )
        try mutateAfterSnapshotRead(command)
        return result
    }

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        let result = try ReleaseQualificationSubprocessRunner().run(
            command,
            limits: limits,
            cancellation: cancellation
        )
        try mutateAfterSnapshotRead(command)
        return result
    }

    private func mutateAfterSnapshotRead(
        _ command: ReleaseQualificationCommandIdentity
    ) throws {
        guard command.purpose.hasPrefix("snapshot committed documentation input bytes ") ||
                command.purpose.hasPrefix("snapshot committed safe-check input bytes ") else {
            return
        }
        try replacement.write(
            to: sourceRoot.appendingPathComponent("README.md"),
            options: .atomic
        )
    }
}

private func releaseQualificationRepositoryCommit(
    _ root: URL
) throws -> ReleaseQualificationCommit {
    let detected = try ReleaseQualificationEnvironmentDetector().detectSourceState(
        sourceRoot: root
    )
    guard let commit = detected.source.commit else {
        throw ReleaseQualificationContractError.staleEvidence
    }
    return commit
}

private func runReleaseQualificationGit(
    _ arguments: [String],
    in root: URL
) throws {
    let result = try ReleaseQualificationSubprocessRunner().run(
        ReleaseQualificationCommandIdentity(
            executablePath: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: root.path,
            purpose: "prepare immutable documentation snapshot fixture"
        ),
        limits: try ReleaseQualificationCommandLimits(),
        cancellation: SecureSubprocessCancellation()
    )
    guard result.exitStatus == 0 else {
        throw ReleaseQualificationCommandError.failed
    }
}

func makeDocumentationSnapshotRepository() throws -> URL {
    let source = ReleaseQualificationTestSupport.repositoryRoot()
    let root = try ReleaseQualificationTestSupport.temporaryDirectory()
    for directory in ["docs", "examples", "schemas", "contracts", "Sources"] {
        try FileManager.default.copyItem(
            at: source.appendingPathComponent(directory, isDirectory: true),
            to: root.appendingPathComponent(directory, isDirectory: true)
        )
    }
    for path in [
        "README.md",
        "CONTRIBUTING.md",
        "GOVERNANCE.md",
        "SECURITY.md",
        "scripts/check-doc-links.py",
        "scripts/check-current-truth.py",
        "scripts/phase09-gate16-qualification.sh",
    ] {
        let destination = root.appendingPathComponent(path)
        let parent = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.copyItem(
            at: source.appendingPathComponent(path),
            to: destination
        )
    }
    try runReleaseQualificationGit(["init", "--quiet"], in: root)
    try runReleaseQualificationGit(["add", "--all"], in: root)
    try runReleaseQualificationGit(
        [
            "-c", "user.name=Hostwright Tests",
            "-c", "user.email=tests@hostwright.invalid",
            "commit", "--quiet", "--no-gpg-sign", "-m", "snapshot fixture",
        ],
        in: root
    )
    return root
}

func makeSafeCheckSnapshotRepository(
    files: [String: Data],
    symbolicLinks: [String: String] = [:],
    gitLinks: [String: String] = [:]
) throws -> URL {
    let root = try ReleaseQualificationTestSupport.temporaryDirectory()
    for path in files.keys.sorted() {
        guard let data = files[path] else { continue }
        let destination = root.appendingPathComponent(path)
        let parent = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try data.write(to: destination, options: [.atomic])
    }
    for path in symbolicLinks.keys.sorted() {
        guard let target = symbolicLinks[path] else { continue }
        let destination = root.appendingPathComponent(path)
        let parent = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: target
        )
    }
    try runReleaseQualificationGit(["init", "--quiet"], in: root)
    try runReleaseQualificationGit(["add", "--all"], in: root)
    for path in gitLinks.keys.sorted() {
        guard let objectID = gitLinks[path] else { continue }
        try runReleaseQualificationGit(
            ["update-index", "--add", "--cacheinfo", "160000,\(objectID),\(path)"],
            in: root
        )
    }
    try runReleaseQualificationGit(
        [
            "-c", "user.name=Hostwright Tests",
            "-c", "user.email=tests@hostwright.invalid",
            "commit", "--quiet", "--no-gpg-sign", "--allow-empty",
            "-m", "safe-check fixture",
        ],
        in: root
    )
    return root
}

func makeLicensePolicySnapshotFixture() throws -> (
    files: [String: Data],
    policy: ReleaseQualificationLicensePolicy
) {
    let source = ReleaseQualificationTestSupport.repositoryRoot()
    var files: [String: Data] = [
        "Package.swift": try Data(contentsOf: source.appendingPathComponent("Package.swift")),
        "Package.resolved": try Data(
            contentsOf: source.appendingPathComponent("Package.resolved")
        ),
    ]
    let pins: [(String, String, String, String)] = [
        (
            "containerization",
            "0.35.0",
            "https://github.com/apple/containerization.git",
            "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b"
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
        ),
        (
            "yams",
            "6.2.2",
            "https://github.com/jpsim/Yams.git",
            "a27b21e0c81c5bf42049b897a62aaf387e80f279"
        ),
    ]
    let entries = pins.map { identity, version, location, revision in
        let path = ReleaseQualificationLicensePolicy.licenseTextPrefix +
            identity + "/LICENSE.txt"
        let text = Data("synthetic license-policy fixture for \(identity)\n".utf8)
        files[path] = text
        return ReleaseQualificationLicensePolicyEntry(
            identity: identity,
            licenseExpression: "MIT",
            licenseTextPath: path,
            licenseTextSHA256: ReleaseQualificationHash.sha256(data: text),
            licenseTextSizeBytes: text.count,
            location: location,
            revision: revision,
            version: version
        )
    }
    let policy = ReleaseQualificationLicensePolicy(
        entries: entries,
        kind: ReleaseQualificationLicensePolicy.kindValue,
        schemaVersion: 1
    )
    files[ReleaseQualificationLicensePolicy.relativePath] = try ReleaseQualificationJSON.encode(
        policy
    )
    return (files, policy)
}

private func releaseQualificationPolicyData(
    entries: [ReleaseQualificationLicensePolicyEntry]
) throws -> Data {
    try ReleaseQualificationJSON.encode(
        ReleaseQualificationLicensePolicy(
            entries: entries,
            kind: ReleaseQualificationLicensePolicy.kindValue,
            schemaVersion: 1
        )
    )
}

private func releaseQualificationPolicyEntry(
    replacing entry: ReleaseQualificationLicensePolicyEntry,
    identity: String? = nil,
    licenseExpression: String? = nil,
    licenseTextPath: String? = nil,
    licenseTextSHA256: ReleaseQualificationSHA256? = nil,
    licenseTextSizeBytes: Int? = nil,
    location: String? = nil,
    revision: String? = nil,
    version: String? = nil
) -> ReleaseQualificationLicensePolicyEntry {
    ReleaseQualificationLicensePolicyEntry(
        identity: identity ?? entry.identity,
        licenseExpression: licenseExpression ?? entry.licenseExpression,
        licenseTextPath: licenseTextPath ?? entry.licenseTextPath,
        licenseTextSHA256: licenseTextSHA256 ?? entry.licenseTextSHA256,
        licenseTextSizeBytes: licenseTextSizeBytes ?? entry.licenseTextSizeBytes,
        location: location ?? entry.location,
        revision: revision ?? entry.revision,
        version: version ?? entry.version
    )
}

private func releaseQualificationMutatedPolicyData(
    _ data: Data,
    mutate: (inout [String: Any]) throws -> Void
) throws -> Data {
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    try mutate(&object)
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func releaseQualificationUTF16Data(
    _ text: String,
    littleEndian: Bool
) -> Data {
    var bytes: [UInt8] = littleEndian ? [0xff, 0xfe] : [0xfe, 0xff]
    for codeUnit in text.utf16 {
        let high = UInt8(truncatingIfNeeded: codeUnit >> 8)
        let low = UInt8(truncatingIfNeeded: codeUnit)
        bytes += littleEndian ? [low, high] : [high, low]
    }
    return Data(bytes)
}

private struct ReleaseQualificationUnavailableSnapshotRunner:
    ReleaseQualificationStandardInputCommandRunning
{
    func run(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        throw ReleaseQualificationCommandError.unavailable
    }

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        throw ReleaseQualificationCommandError.unavailable
    }
}

private struct ReleaseQualificationRecordingSnapshotRunner:
    ReleaseQualificationStandardInputCommandRunning
{
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(purpose: String, input: Data)] = []

        func record(purpose: String, input: Data) {
            lock.lock()
            storage.append((purpose, input))
            lock.unlock()
        }

        func requests() -> [(purpose: String, input: Data)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private let subprocess = ReleaseQualificationSubprocessRunner()
    private let state = State()

    var requests: [(purpose: String, input: Data)] {
        state.requests()
    }

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        if let standardInput {
            state.record(purpose: command.purpose, input: standardInput)
        }
        return try subprocess.run(
            command,
            standardInput: standardInput,
            limits: limits,
            cancellation: cancellation
        )
    }

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        try subprocess.run(command, limits: limits, cancellation: cancellation)
    }
}

final class ReleaseQualificationRegistryTests: XCTestCase {
    func testDefaultRegistryPlansReadyLocalLanesAndExplicitBlockers() throws {
        let root = ReleaseQualificationTestSupport.repositoryRoot()
        let document = try ReleaseQualificationRegistryPlanner(
            pythonLocator: ReleaseQualificationFixedPythonLocator(path: "/usr/bin/python3")
        ).plan(sourceRoot: root)
        try document.validate()
        XCTAssertEqual(document.registry.lanes.count, document.lanes.count)
        XCTAssertEqual(
            document.lanes.first(where: { $0.laneID == "qualification-json-boundary" })?.status,
            .ready
        )
        let protocolPlan = try XCTUnwrap(
            document.lanes.first(where: { $0.laneID == "phase08-protocol-fuzz" })
        )
        XCTAssertFalse(protocolPlan.blockers.contains {
            $0.reason == .liveRuntimePhase08Boundary
        })
        XCTAssertTrue(protocolPlan.blockers.contains {
            $0.reason == .fuzzingProviderUnavailable
        })
        XCTAssertTrue(document.lanes.contains {
            $0.blockers.contains { $0.reason == .sanitizerUnavailable }
        })
        let documentation = try XCTUnwrap(
            document.registry.lanes.first { $0.id == "documentation-source-contracts" }
        )
        XCTAssertEqual(documentation.kind, .dependency)
        XCTAssertEqual(
            document.lanes.first { $0.laneID == documentation.id }?.status,
            .ready
        )
        XCTAssertTrue(documentation.exclusions.contains {
            $0.contains("separately deployed website")
        })
        let license = try XCTUnwrap(
            document.registry.lanes.first { $0.id == "license-policy" }
        )
        XCTAssertEqual(license.kind, .license)
        let licensePlan = try XCTUnwrap(
            document.lanes.first { $0.laneID == license.id }
        )
        XCTAssertEqual(licensePlan.status, .blocked)
        XCTAssertEqual(licensePlan.blockers.map(\.reason), [.sourceCommitUnavailable])
        XCTAssertEqual(
            licensePlan.blockers[0].detail,
            "license-policy execution requires an exact source commit and dirty-state identity"
        )
        XCTAssertTrue(license.exclusions.contains { $0.contains("legal compliance") })
        XCTAssertTrue(license.exclusions.contains { $0.contains("transitive") })
    }

    func testLicensePolicyPlanNeverPromotesMutableWorkingTreeFactsWithoutCommitAuthority() throws {
        var matching = try makeLicensePolicySnapshotFixture().files
        var stalePin = matching
        let policyData = try XCTUnwrap(
            stalePin[ReleaseQualificationLicensePolicy.relativePath]
        )
        stalePin[ReleaseQualificationLicensePolicy.relativePath] =
            try releaseQualificationMutatedPolicyData(policyData) { object in
                var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
                entries[0]["revision"] = String(repeating: "0", count: 40)
                object["entries"] = entries
            }
        var extraText = matching
        extraText[ReleaseQualificationLicensePolicy.licenseTextPrefix +
            "unreferenced/LICENSE.txt"] = Data("unreferenced\n".utf8)
        matching["uncommitted-marker"] = Data("mutable working tree\n".utf8)

        let roots = try [[:], matching, stalePin, extraText].map {
            try makeSafeCheckSnapshotRepository(files: $0)
        }
        defer {
            for root in roots { try? FileManager.default.removeItem(at: root) }
        }

        for root in roots {
            let document = try ReleaseQualificationRegistryPlanner().plan(
                sourceRoot: root
            )
            let plan = try XCTUnwrap(
                document.lanes.first { $0.laneID == "license-policy" }
            )
            XCTAssertEqual(plan.status, .blocked)
            XCTAssertEqual(plan.blockers.map(\.reason), [.sourceCommitUnavailable])
            XCTAssertEqual(
                plan.blockers[0].detail,
                "license-policy execution requires an exact source commit and dirty-state identity"
            )
        }
    }

    func testLicensePolicyPlanMatchesExactCommittedReceiptsAndDirtyAuthority() throws {
        let fixture = try makeLicensePolicySnapshotFixture()
        let root = try makeSafeCheckSnapshotRepository(files: fixture.files)
        defer { try? FileManager.default.removeItem(at: root) }
        let detected = try ReleaseQualificationEnvironmentDetector().detectSourceState(
            sourceRoot: root
        )
        let planner = ReleaseQualificationRegistryPlanner()
        let ready = try planner.plan(
            sourceRoot: root,
            environment: ReleaseQualificationTestSupport.environment(
                source: detected.source,
                workingDirectory: root.path
            )
        )
        let readyPlan = try XCTUnwrap(
            ready.lanes.first { $0.laneID == "license-policy" }
        )
        XCTAssertEqual(readyPlan.status, .ready)
        XCTAssertTrue(readyPlan.blockers.isEmpty)

        let commit = try XCTUnwrap(detected.source.commit)
        let dirty = try planner.plan(
            sourceRoot: root,
            environment: ReleaseQualificationTestSupport.environment(
                source: ReleaseQualificationSourceFacts(
                    availability: .init(status: .available),
                    commit: commit,
                    dirty: true,
                    dirtyStateSHA256: ReleaseQualificationHash.sha256(
                        data: Data("dirty".utf8)
                    )
                ),
                workingDirectory: root.path
            )
        )
        let dirtyPlan = try XCTUnwrap(
            dirty.lanes.first { $0.laneID == "license-policy" }
        )
        XCTAssertEqual(dirtyPlan.status, .blocked)
        XCTAssertEqual(dirtyPlan.blockers.map(\.reason), [.dirtySource])
    }

    func testLicensePolicyPlanBlocksExactCommitWithEmptyOrMissingReceipts() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let committedEmptyFiles: [String: Data] = [
            "Package.swift": try Data(
                contentsOf: source.appendingPathComponent("Package.swift")
            ),
            "Package.resolved": try Data(
                contentsOf: source.appendingPathComponent("Package.resolved")
            ),
            ReleaseQualificationLicensePolicy.relativePath: try Data(
                contentsOf: source.appendingPathComponent(
                    ReleaseQualificationLicensePolicy.relativePath
                )
            ),
        ]
        let missingPolicyFiles = committedEmptyFiles.filter {
            $0.key != ReleaseQualificationLicensePolicy.relativePath
        }
        let roots = try [committedEmptyFiles, missingPolicyFiles].map {
            try makeSafeCheckSnapshotRepository(files: $0)
        }
        defer {
            for root in roots { try? FileManager.default.removeItem(at: root) }
        }

        let plans = try roots.map { root in
            let detected = try ReleaseQualificationEnvironmentDetector().detectSourceState(
                sourceRoot: root
            )
            let document = try ReleaseQualificationRegistryPlanner().plan(
                sourceRoot: root,
                environment: ReleaseQualificationTestSupport.environment(
                    source: detected.source,
                    workingDirectory: root.path
                )
            )
            return try XCTUnwrap(
                document.lanes.first { $0.laneID == "license-policy" }
            )
        }

        XCTAssertEqual(plans[0].status, .blocked)
        XCTAssertEqual(plans[0].blockers.map(\.reason), [.licenseMetadataUnavailable])
        XCTAssertEqual(
            plans[0].blockers[0].detail,
            "committed license-policy receipts are missing for identities: " +
                "containerization, swift-certificates, wasmkit, yams"
        )
        XCTAssertEqual(plans[1].status, .blocked)
        XCTAssertEqual(plans[1].blockers.map(\.reason), [.licenseMetadataUnavailable])
        XCTAssertTrue(plans[1].blockers[0].detail.contains("license-policy.json"))
    }

    func testLicensePolicyPlanBlocksFailedExactCommitIntegrityAsTampered() throws {
        var fixture = try makeLicensePolicySnapshotFixture()
        let policyData = try XCTUnwrap(
            fixture.files[ReleaseQualificationLicensePolicy.relativePath]
        )
        fixture.files[ReleaseQualificationLicensePolicy.relativePath] =
            try releaseQualificationMutatedPolicyData(policyData) { object in
                var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
                entries[0]["revision"] = String(repeating: "0", count: 40)
                object["entries"] = entries
            }
        let root = try makeSafeCheckSnapshotRepository(files: fixture.files)
        defer { try? FileManager.default.removeItem(at: root) }
        let detected = try ReleaseQualificationEnvironmentDetector().detectSourceState(
            sourceRoot: root
        )

        let document = try ReleaseQualificationRegistryPlanner().plan(
            sourceRoot: root,
            environment: ReleaseQualificationTestSupport.environment(
                source: detected.source,
                workingDirectory: root.path
            )
        )
        let plan = try XCTUnwrap(
            document.lanes.first { $0.laneID == "license-policy" }
        )

        XCTAssertEqual(plan.status, .blocked)
        XCTAssertEqual(plan.blockers.map(\.reason), [.tamperedEvidence])
        XCTAssertEqual(
            plan.blockers[0].detail,
            "the exact committed license-policy inputs fail integrity validation"
        )
    }

    func testDocumentationLanePlanBlocksWhenTrustedPythonIsUnavailable() throws {
        let root = ReleaseQualificationTestSupport.repositoryRoot()
        let document = try ReleaseQualificationRegistryPlanner(
            pythonLocator: ReleaseQualificationFixedPythonLocator(path: nil)
        ).plan(sourceRoot: root)
        let documentation = try XCTUnwrap(
            document.lanes.first { $0.laneID == "documentation-source-contracts" }
        )

        XCTAssertEqual(documentation.status, .blocked)
        XCTAssertEqual(documentation.blockers.map(\.reason), [.dependencyUnavailable])
    }

    func testParserBoundaryHarnessAcceptsCanonicalAndRejectsUnknownData() throws {
        let budget = ReleaseQualificationBudget(
            maximumDurationSeconds: 30,
            maximumCPUHours: 0,
            maximumInputBytes: 4_096,
            maximumOutputBytes: 1_024
        )
        let valid = try ReleaseQualificationJSON.encode(budget)
        XCTAssertTrue(
            ReleaseQualificationParserBoundaryHarness.evaluate(
                data: valid,
                target: .qualificationContractJSON
            )
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["unknownFutureField"] = true
        let unknown = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let result = ReleaseQualificationParserBoundaryHarness.evaluate(
            data: unknown,
            target: .qualificationContractJSON,
            expectation: .reject
        )
        XCTAssertTrue(result.satisfied)
        XCTAssertFalse(result.accepted)
    }

    func testMissingOrTamperedSeededCorpusIsBlocked() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpusDirectory = root
            .appendingPathComponent("Tests/HostwrightReleaseQualificationTests/Fixtures/corpus")
        try FileManager.default.createDirectory(
            at: corpusDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let source = ReleaseQualificationTestSupport.repositoryRoot()
            .appendingPathComponent(
                "Tests/HostwrightReleaseQualificationTests/Fixtures/corpus/qualification-budget-valid.json"
            )
        let destination = corpusDirectory.appendingPathComponent(
            "qualification-budget-valid.json"
        )
        var data = try Data(contentsOf: source)
        data.append(Data("x".utf8))
        try data.write(to: destination, options: [.atomic])
        let document = try ReleaseQualificationRegistryPlanner().plan(sourceRoot: root)
        let plan = try XCTUnwrap(
            document.lanes.first(where: { $0.laneID == "qualification-json-boundary" })
        )
        XCTAssertTrue(plan.blockers.contains {
            $0.reason == .tamperedEvidence || $0.reason == .corpusMismatch
        })
    }

    func testSafeChecksUseRealBoundedInputsAndAggregateDeterministically() throws {
        let results = try ReleaseQualificationSafeCheckRunner().run(
            sourceRoot: ReleaseQualificationTestSupport.repositoryRoot()
        )
        XCTAssertEqual(
            results.map(\.checkID),
            ["dependency-lock-integrity", "secret-scan"]
        )
        XCTAssertEqual(results[0].status, .passed)
        XCTAssertEqual(results[1].status, .failed)
        XCTAssertTrue(
            results[1].failures.contains {
                $0.contains("AWS-access-key") || $0.contains("GitHub-token")
            }
        )
        XCTAssertEqual(
            try ReleaseQualificationSafeCheckAggregation.status(results),
            .failed
        )
    }

    func testDependencyLockLaneUsesExactCommitBlobsForPassFailureAndBlock() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let package = try Data(contentsOf: source.appendingPathComponent("Package.swift"))
        let resolved = try Data(contentsOf: source.appendingPathComponent("Package.resolved"))
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "dependency-lock-integrity"
            }
        )

        let passingRoot = try makeSafeCheckSnapshotRepository(
            files: ["Package.swift": package, "Package.resolved": resolved]
        )
        defer { try? FileManager.default.removeItem(at: passingRoot) }
        let recordingRunner = ReleaseQualificationRecordingSnapshotRunner()
        let passing = try ReleaseQualificationLocalLaneRunner(
            sourceSnapshotRunner: recordingRunner
        ).run(
            lane: lane,
            sourceRoot: passingRoot,
            sourceCommit: try releaseQualificationRepositoryCommit(passingRoot)
        )
        XCTAssertEqual(passing.status, .passed)
        XCTAssertTrue(passing.failures.isEmpty)
        XCTAssertTrue(passing.blockers.isEmpty)
        XCTAssertEqual(
            passing.commands.first?.identity.purpose,
            "snapshot committed safe-check input names"
        )
        let blobCommands = passing.commands.dropFirst()
        XCTAssertFalse(blobCommands.isEmpty)
        XCTAssertTrue(blobCommands.allSatisfy {
            $0.identity.purpose.range(
                of: #"^snapshot committed safe-check input bytes request-sha256=[a-f0-9]{64}$"#,
                options: .regularExpression
            ) != nil
        })
        XCTAssertEqual(
            Set(blobCommands.map(\.identity.purpose)).count,
            blobCommands.count
        )
        XCTAssertFalse(recordingRunner.requests.isEmpty)
        XCTAssertTrue(recordingRunner.requests.allSatisfy { request in
            request.purpose ==
                "snapshot committed safe-check input bytes request-sha256=" +
                ReleaseQualificationHash.sha256(data: request.input).value
        })
        XCTAssertEqual(
            passing.commands.map { $0.identity.executablePath },
            Array(repeating: "/usr/bin/git", count: passing.commands.count)
        )
        XCTAssertEqual(
            passing.commands.first.map { Array($0.identity.arguments.suffix(2)) },
            [
                "--full-tree",
                try releaseQualificationRepositoryCommit(passingRoot).value,
            ]
        )

        let failingRoot = try makeSafeCheckSnapshotRepository(
            files: [
                "Package.swift": Data("// swift-tools-version: 6.2\n".utf8),
                "Package.resolved": resolved,
            ]
        )
        defer { try? FileManager.default.removeItem(at: failingRoot) }
        let failing = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: failingRoot,
            sourceCommit: try releaseQualificationRepositoryCommit(failingRoot)
        )
        XCTAssertEqual(failing.status, .failed)
        XCTAssertTrue(failing.blockers.isEmpty)
        XCTAssertTrue(failing.failures.contains { $0.contains("Package.swift direct dependencies") })

        let blockedRoot = try makeSafeCheckSnapshotRepository(
            files: ["Package.swift": package]
        )
        defer { try? FileManager.default.removeItem(at: blockedRoot) }
        let blocked = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: blockedRoot,
            sourceCommit: try releaseQualificationRepositoryCommit(blockedRoot)
        )
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.blockers.map(\.reason), [.dependencyUnavailable])
        XCTAssertTrue(blocked.failures.isEmpty)
    }

    func testSafeLanesIgnoreValidatedUnrelatedSymlinkAndGitlinkEntries() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let package = try Data(contentsOf: source.appendingPathComponent("Package.swift"))
        let resolved = try Data(contentsOf: source.appendingPathComponent("Package.resolved"))
        let root = try makeSafeCheckSnapshotRepository(
            files: [
                "Package.swift": package,
                "Package.resolved": resolved,
                "README.md": Data("bounded clean fixture\n".utf8),
            ],
            symbolicLinks: ["unrelated-link": "README.md"],
            gitLinks: ["vendor/unrelated": ReleaseQualificationTestSupport.commit.value]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let commit = try releaseQualificationRepositoryCommit(root)

        for laneID in ["dependency-lock-integrity", "secret-scan"] {
            let lane = try XCTUnwrap(
                ReleaseQualificationDefaultRegistry.registry.lanes.first { $0.id == laneID }
            )
            let execution = try ReleaseQualificationLocalLaneRunner().run(
                lane: lane,
                sourceRoot: root,
                sourceCommit: commit
            )
            XCTAssertEqual(execution.status, .passed, laneID)
            XCTAssertTrue(execution.blockers.isEmpty, laneID)
            XCTAssertTrue(execution.failures.isEmpty, laneID)
        }
    }

    func testDependencyLockLaneBlocksWhenRequiredPackageManifestIsASymlink() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let package = try Data(contentsOf: source.appendingPathComponent("Package.swift"))
        let resolved = try Data(contentsOf: source.appendingPathComponent("Package.resolved"))
        let root = try makeSafeCheckSnapshotRepository(
            files: [
                "CanonicalPackage.swift": package,
                "Package.resolved": resolved,
            ],
            symbolicLinks: ["Package.swift": "CanonicalPackage.swift"]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "dependency-lock-integrity"
            }
        )

        let execution = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )

        XCTAssertEqual(execution.status, .blocked)
        XCTAssertEqual(execution.blockers.map(\.reason), [.dependencyUnavailable])
        XCTAssertTrue(execution.failures.isEmpty)
    }

    func testSecretScanLaneUsesBoundedExactCommitBlobsForPassFailureAndBlock() throws {
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "secret-scan"
            }
        )
        let passingRoot = try makeSafeCheckSnapshotRepository(
            files: ["README.md": Data("bounded clean fixture\n".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: passingRoot) }
        let passing = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: passingRoot,
            sourceCommit: try releaseQualificationRepositoryCommit(passingRoot)
        )
        XCTAssertEqual(passing.status, .passed)
        XCTAssertTrue(passing.commands.allSatisfy {
            $0.identity.purpose.hasPrefix("snapshot committed safe-check input")
        })

        let credential = "AKIA" + String(repeating: "A", count: 16)
        let failingRoot = try makeSafeCheckSnapshotRepository(
            files: ["config.txt": Data((credential + "\n").utf8)]
        )
        defer { try? FileManager.default.removeItem(at: failingRoot) }
        let failing = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: failingRoot,
            sourceCommit: try releaseQualificationRepositoryCommit(failingRoot)
        )
        XCTAssertEqual(failing.status, .failed)
        XCTAssertEqual(failing.failures, ["high-confidence AWS-access-key pattern in config.txt"])
        XCTAssertTrue(failing.blockers.isEmpty)

        let blocked = try ReleaseQualificationLocalLaneRunner(
            sourceSnapshotRunner: ReleaseQualificationUnavailableSnapshotRunner()
        ).run(
            lane: lane,
            sourceRoot: passingRoot,
            sourceCommit: try releaseQualificationRepositoryCommit(passingRoot)
        )
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.blockers.map(\.reason), [.dependencyUnavailable])
        XCTAssertTrue(blocked.commands.isEmpty)
    }

    func testSecretScanLaneScansInvalidUTF8AndUTF16WithoutExposingCredentials() throws {
        let invalidUTF8Credential = "AKIA" + String(repeating: "D", count: 16)
        var invalidUTF8 = Data([0xff])
        invalidUTF8.append(contentsOf: invalidUTF8Credential.utf8)
        invalidUTF8.append(0xfe)
        let littleEndianCredential = "ghp_" + String(repeating: "e", count: 20)
        let bigEndianCredential = "xoxb-" + String(repeating: "F", count: 20)
        let root = try makeSafeCheckSnapshotRepository(
            files: [
                "invalid.bin": invalidUTF8,
                "utf16-be.txt": releaseQualificationUTF16Data(
                    bigEndianCredential,
                    littleEndian: false
                ),
                "utf16-le.txt": releaseQualificationUTF16Data(
                    littleEndianCredential,
                    littleEndian: true
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first { $0.id == "secret-scan" }
        )

        let execution = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )

        XCTAssertEqual(execution.status, .failed)
        XCTAssertEqual(
            Set(execution.failures),
            Set([
                "high-confidence AWS-access-key pattern in invalid.bin",
                "high-confidence GitHub-token pattern in utf16-le.txt",
                "high-confidence Slack-token pattern in utf16-be.txt",
            ])
        )
        let reported = execution.failures.joined(separator: "\n")
        XCTAssertFalse(reported.contains(invalidUTF8Credential))
        XCTAssertFalse(reported.contains(littleEndianCredential))
        XCTAssertFalse(reported.contains(bigEndianCredential))
        XCTAssertTrue(execution.blockers.isEmpty)
    }

    func testSecretScanLaneBlocksUnsupportedUTF32Input() throws {
        let root = try makeSafeCheckSnapshotRepository(
            files: ["utf32.bin": Data([0xff, 0xfe, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first { $0.id == "secret-scan" }
        )

        let execution = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )

        XCTAssertEqual(execution.status, .blocked)
        XCTAssertEqual(execution.blockers.map(\.reason), [.secretScanUnavailable])
        XCTAssertTrue(execution.failures.isEmpty)
    }

    func testDependencyLockLaneRejectsCrossPairedURLAndExactVersionText() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let resolved = try Data(contentsOf: source.appendingPathComponent("Package.resolved"))
        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "adversarial", dependencies: [
            .package(url: "https://github.com/apple/containerization.git", from: "0.35.0"),
            .package(url: "https://invalid.example/containerization.git", exact: "0.35.0"),
            .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
            .package(url: "https://invalid.example/Yams.git", exact: "6.2.2"),
            .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.3"),
            .package(url: "https://invalid.example/swift-certificates.git", exact: "1.19.3"),
            .package(url: "https://github.com/swiftwasm/WasmKit.git", from: "0.3.1"),
            .package(url: "https://invalid.example/WasmKit.git", exact: "0.3.1")
        ])
        """
        let root = try makeSafeCheckSnapshotRepository(
            files: [
                "Package.swift": Data(manifest.utf8),
                "Package.resolved": resolved,
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "dependency-lock-integrity"
            }
        )

        let execution = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )

        XCTAssertEqual(execution.status, .failed)
        XCTAssertEqual(
            execution.failures,
            ["Package.swift direct dependencies are not exactly the canonical four exact pins"]
        )
        XCTAssertTrue(execution.blockers.isEmpty)
    }

    func testDependencyLockLaneIgnoresCanonicalTextInCommentAndRejectsRealFromCall() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let resolved = try Data(contentsOf: source.appendingPathComponent("Package.resolved"))
        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "adversarial", dependencies: [
            /* .package(
                url: "https://github.com/apple/containerization.git",
                exact: "0.35.0"
            ), */
            .package(url: "https://github.com/apple/containerization.git", from: "0.35.0"),
            .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
            .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.19.3"),
            .package(url: "https://github.com/swiftwasm/WasmKit.git", exact: "0.3.1")
        ])
        """
        let execution = try dependencyLaneExecution(
            packageManifest: manifest,
            packageResolved: resolved
        )

        XCTAssertEqual(execution.status, .failed)
        XCTAssertEqual(
            execution.failures,
            ["Package.swift direct dependencies are not exactly the canonical four exact pins"]
        )
    }

    func testDependencyLockLaneRejectsAdditionalDirectDependency() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let resolved = try Data(contentsOf: source.appendingPathComponent("Package.resolved"))
        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "adversarial", dependencies: [
            .package(url: "https://github.com/apple/containerization.git", exact: "0.35.0"),
            .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
            .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.19.3"),
            .package(url: "https://github.com/swiftwasm/WasmKit.git", exact: "0.3.1"),
            .package(url: "https://malicious.invalid/extra.git", branch: "main")
        ])
        """
        let execution = try dependencyLaneExecution(
            packageManifest: manifest,
            packageResolved: resolved
        )

        XCTAssertEqual(execution.status, .failed)
        XCTAssertEqual(
            execution.failures,
            ["Package.swift direct dependencies are not exactly the canonical four exact pins"]
        )
    }

    func testDependencyLockLaneTreatsOriginHashAsStructuralAndRequiresExactRevision() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let package = try String(
            contentsOf: source.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let resolved = try String(
            contentsOf: source.appendingPathComponent("Package.resolved"),
            encoding: .utf8
        )
        let alternateOrigin = resolved.replacingOccurrences(
            of: "a9fe88d21d915412c23448357e6989143a521ccecf99c87e4034fdf3bae6c046",
            with: String(repeating: "f", count: 64)
        )
        let structurallyValid = try dependencyLaneExecution(
            packageManifest: package,
            packageResolved: Data(alternateOrigin.utf8)
        )
        XCTAssertEqual(structurallyValid.status, .passed)
        XCTAssertTrue(structurallyValid.failures.isEmpty)

        let malformedOrigin = resolved.replacingOccurrences(
            of: "a9fe88d21d915412c23448357e6989143a521ccecf99c87e4034fdf3bae6c046",
            with: String(repeating: "f", count: 63)
        )
        let malformed = try dependencyLaneExecution(
            packageManifest: package,
            packageResolved: Data(malformedOrigin.utf8)
        )
        XCTAssertEqual(malformed.status, .failed)
        XCTAssertEqual(
            malformed.failures,
            ["Package.resolved has malformed origin or pin data"]
        )

        let wrongRevision = resolved.replacingOccurrences(
            of: "44bec8b9933bc491d0cbf44abac90a1f6aaebf6b",
            with: String(repeating: "0", count: 40)
        )
        let revisionMismatch = try dependencyLaneExecution(
            packageManifest: package,
            packageResolved: Data(wrongRevision.utf8)
        )
        XCTAssertEqual(revisionMismatch.status, .failed)
        XCTAssertEqual(
            revisionMismatch.failures,
            ["Package.resolved direct pin containerization has an unexpected revision"]
        )

        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "dependency-lock-integrity"
            }
        )
        XCTAssertEqual(
            lane.target,
            "canonical direct pins and structural Package.resolved schema"
        )
    }

    private func dependencyLaneExecution(
        packageManifest: String,
        packageResolved: Data
    ) throws -> ReleaseQualificationLaneExecution {
        let root = try makeSafeCheckSnapshotRepository(
            files: [
                "Package.swift": Data(packageManifest.utf8),
                "Package.resolved": packageResolved,
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "dependency-lock-integrity"
            }
        )
        return try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )
    }

    func testLicensePolicyLanePassesOnlyExactCommittedReceiptsAndTexts() throws {
        let fixture = try makeLicensePolicySnapshotFixture()
        let execution = try licensePolicyLaneExecution(files: fixture.files)

        XCTAssertEqual(execution.status, .passed)
        XCTAssertTrue(execution.blockers.isEmpty)
        XCTAssertTrue(execution.failures.isEmpty)
        XCTAssertEqual(
            execution.commands.first?.identity.purpose,
            "snapshot committed safe-check input names"
        )
        XCTAssertTrue(execution.commands.dropFirst().allSatisfy {
            $0.identity.purpose.hasPrefix(
                "snapshot committed safe-check input bytes request-sha256="
            )
        })
    }

    func testLicensePolicyLaneBlocksMissingPolicyAndMissingDirectReceipt() throws {
        var fixture = try makeLicensePolicySnapshotFixture()
        fixture.files.removeValue(forKey: ReleaseQualificationLicensePolicy.relativePath)
        let missingPolicy = try licensePolicyLaneExecution(files: fixture.files)
        XCTAssertEqual(missingPolicy.status, .blocked)
        XCTAssertEqual(missingPolicy.blockers.map(\.reason), [.licenseMetadataUnavailable])
        XCTAssertTrue(missingPolicy.blockers[0].detail.contains("license-policy.json"))

        fixture = try makeLicensePolicySnapshotFixture()
        let missingIdentity = "yams"
        let entries = fixture.policy.entries.filter { $0.identity != missingIdentity }
        fixture.files[ReleaseQualificationLicensePolicy.relativePath] =
            try releaseQualificationPolicyData(entries: entries)
        fixture.files.removeValue(
            forKey: ReleaseQualificationLicensePolicy.licenseTextPrefix +
                missingIdentity + "/LICENSE.txt"
        )
        let missingReceipt = try licensePolicyLaneExecution(files: fixture.files)
        XCTAssertEqual(missingReceipt.status, .blocked)
        XCTAssertEqual(missingReceipt.blockers.map(\.reason), [.licenseMetadataUnavailable])
        XCTAssertEqual(
            missingReceipt.blockers[0].detail,
            "committed license-policy receipts are missing for identities: yams"
        )
    }

    func testCommittedEmptyLicensePolicyBlocksWithExactMissingIdentities() throws {
        let source = ReleaseQualificationTestSupport.repositoryRoot()
        let files: [String: Data] = [
            "Package.swift": try Data(
                contentsOf: source.appendingPathComponent("Package.swift")
            ),
            "Package.resolved": try Data(
                contentsOf: source.appendingPathComponent("Package.resolved")
            ),
            ReleaseQualificationLicensePolicy.relativePath: try Data(
                contentsOf: source.appendingPathComponent(
                    ReleaseQualificationLicensePolicy.relativePath
                )
            ),
        ]

        let execution = try licensePolicyLaneExecution(files: files)

        XCTAssertEqual(execution.status, .blocked)
        XCTAssertEqual(execution.blockers.map(\.reason), [.licenseMetadataUnavailable])
        XCTAssertEqual(
            execution.blockers[0].detail,
            "committed license-policy receipts are missing for identities: " +
                "containerization, swift-certificates, wasmkit, yams"
        )
        XCTAssertTrue(execution.failures.isEmpty)
    }

    func testLicensePolicyLaneRejectsMalformedUnknownSPDXDuplicateAndUnknownKeys() throws {
        let fixture = try makeLicensePolicySnapshotFixture()
        let policyData = try XCTUnwrap(
            fixture.files[ReleaseQualificationLicensePolicy.relativePath]
        )
        let malformed = Data("{\"entries\":[".utf8)
        let unknownSPDX = try releaseQualificationMutatedPolicyData(policyData) { object in
            var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
            entries[0]["licenseExpression"] = "GPL-3.0-only"
            object["entries"] = entries
        }
        let duplicate = try releaseQualificationMutatedPolicyData(policyData) { object in
            var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
            entries.insert(entries[0], at: 1)
            object["entries"] = entries
        }
        let unknownKey = try releaseQualificationMutatedPolicyData(policyData) { object in
            object["futureLegalConclusion"] = true
        }
        let futureSchema = try releaseQualificationMutatedPolicyData(policyData) { object in
            object["schemaVersion"] = 2
        }
        let unsorted = try releaseQualificationMutatedPolicyData(policyData) { object in
            let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
            object["entries"] = Array(entries.reversed())
        }
        let uppercaseSHA = try releaseQualificationMutatedPolicyData(policyData) { object in
            var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
            entries[0]["licenseTextSHA256"] = String(repeating: "A", count: 64)
            object["entries"] = entries
        }

        for (label, candidate) in [
            ("malformed", malformed),
            ("unknown SPDX", unknownSPDX),
            ("duplicate", duplicate),
            ("unknown key", unknownKey),
            ("future schema", futureSchema),
            ("unsorted", unsorted),
            ("uppercase SHA", uppercaseSHA),
        ] {
            var files = fixture.files
            files[ReleaseQualificationLicensePolicy.relativePath] = candidate
            let execution = try licensePolicyLaneExecution(files: files)
            XCTAssertEqual(execution.status, .failed, label)
            XCTAssertEqual(
                execution.failures,
                [
                    "license policy is malformed or non-canonical at " +
                        ReleaseQualificationLicensePolicy.relativePath
                ],
                label
            )
        }
    }

    func testLicensePolicyLaneRejectsExtraReceiptAndDirectPinMismatch() throws {
        var fixture = try makeLicensePolicySnapshotFixture()
        let extraText = Data("synthetic extra receipt\n".utf8)
        let extraPath = ReleaseQualificationLicensePolicy.licenseTextPrefix +
            "extra/LICENSE.txt"
        let extra = ReleaseQualificationLicensePolicyEntry(
            identity: "extra",
            licenseExpression: "BSD-2-Clause",
            licenseTextPath: extraPath,
            licenseTextSHA256: ReleaseQualificationHash.sha256(data: extraText),
            licenseTextSizeBytes: extraText.count,
            location: "https://example.invalid/fixtures/extra.git",
            revision: String(repeating: "e", count: 40),
            version: "1.0.0"
        )
        var entries = fixture.policy.entries
        entries.append(extra)
        entries.sort { $0.identity < $1.identity }
        fixture.files[extraPath] = extraText
        fixture.files[ReleaseQualificationLicensePolicy.relativePath] =
            try releaseQualificationPolicyData(entries: entries)
        let extraReceipt = try licensePolicyLaneExecution(files: fixture.files)
        XCTAssertEqual(extraReceipt.status, .failed)
        XCTAssertEqual(
            extraReceipt.failures,
            ["license policy has an unexpected direct receipt for extra"]
        )

        fixture = try makeLicensePolicySnapshotFixture()
        entries = fixture.policy.entries
        entries[0] = releaseQualificationPolicyEntry(
            replacing: entries[0],
            version: "9.9.9"
        )
        fixture.files[ReleaseQualificationLicensePolicy.relativePath] =
            try releaseQualificationPolicyData(entries: entries)
        let staleReceipt = try licensePolicyLaneExecution(files: fixture.files)
        XCTAssertEqual(staleReceipt.status, .failed)
        XCTAssertEqual(
            staleReceipt.failures,
            [
                "license policy receipt containerization does not match the direct pin version"
            ]
        )

        fixture = try makeLicensePolicySnapshotFixture()
        entries = fixture.policy.entries
        entries[0] = releaseQualificationPolicyEntry(
            replacing: entries[0],
            location: "https://example.invalid/apple/containerization.git",
            revision: String(repeating: "0", count: 40)
        )
        fixture.files[ReleaseQualificationLicensePolicy.relativePath] =
            try releaseQualificationPolicyData(entries: entries)
        let wrongLocationAndRevision = try licensePolicyLaneExecution(files: fixture.files)
        XCTAssertEqual(wrongLocationAndRevision.status, .failed)
        XCTAssertEqual(
            wrongLocationAndRevision.failures,
            [
                "license policy receipt containerization does not match the direct pin location",
                "license policy receipt containerization does not match the direct pin revision",
            ]
        )
    }

    func testLicensePolicyLaneRejectsHashSizeAndTraversalWithoutTextLeakage() throws {
        var fixture = try makeLicensePolicySnapshotFixture()
        let privateText = "PRIVATE-LICENSE-TEXT-MUST-NOT-LEAK"
        let entry = fixture.policy.entries[0]
        fixture.files[entry.licenseTextPath] = Data(privateText.utf8)
        var entries = fixture.policy.entries
        entries[0] = releaseQualificationPolicyEntry(
            replacing: entry,
            licenseTextSHA256: try ReleaseQualificationSHA256(
                String(repeating: "0", count: 64)
            ),
            licenseTextSizeBytes: Data(privateText.utf8).count + 1
        )
        fixture.files[ReleaseQualificationLicensePolicy.relativePath] =
            try releaseQualificationPolicyData(entries: entries)
        let mismatch = try licensePolicyLaneExecution(files: fixture.files)
        XCTAssertEqual(mismatch.status, .failed)
        XCTAssertEqual(mismatch.failures.count, 2)
        XCTAssertTrue(mismatch.failures.contains { $0.contains("size does not match") })
        XCTAssertTrue(mismatch.failures.contains { $0.contains("SHA-256 does not match") })
        XCTAssertFalse(mismatch.failures.joined().contains(privateText))

        fixture = try makeLicensePolicySnapshotFixture()
        let policyData = try XCTUnwrap(
            fixture.files[ReleaseQualificationLicensePolicy.relativePath]
        )
        fixture.files[ReleaseQualificationLicensePolicy.relativePath] =
            try releaseQualificationMutatedPolicyData(policyData) { object in
                var rawEntries = try XCTUnwrap(object["entries"] as? [[String: Any]])
                rawEntries[0]["licenseTextPath"] = "../PRIVATE-LICENSE-TEXT-MUST-NOT-LEAK"
                object["entries"] = rawEntries
            }
        let traversal = try licensePolicyLaneExecution(files: fixture.files)
        XCTAssertEqual(traversal.status, .failed)
        XCTAssertFalse(traversal.failures.joined().contains(privateText))
    }

    func testLicensePolicyLaneRejectsCommittedSymlinkAndGitlinkLicenseTexts() throws {
        let fixture = try makeLicensePolicySnapshotFixture()
        let entry = fixture.policy.entries[0]

        var symlinkFiles = fixture.files
        symlinkFiles.removeValue(forKey: entry.licenseTextPath)
        symlinkFiles["fixture-license-target.txt"] = Data("fixture target\n".utf8)
        let symlink = try licensePolicyLaneExecution(
            files: symlinkFiles,
            symbolicLinks: [entry.licenseTextPath: "../../../fixture-license-target.txt"]
        )
        XCTAssertEqual(symlink.status, .blocked)
        XCTAssertEqual(symlink.blockers.map(\.reason), [.unsafePath])
        XCTAssertTrue(symlink.blockers[0].detail.contains(entry.licenseTextPath))

        var gitlinkFiles = fixture.files
        gitlinkFiles.removeValue(forKey: entry.licenseTextPath)
        let gitlink = try licensePolicyLaneExecution(
            files: gitlinkFiles,
            gitLinks: [entry.licenseTextPath: ReleaseQualificationTestSupport.commit.value]
        )
        XCTAssertEqual(gitlink.status, .blocked)
        XCTAssertEqual(gitlink.blockers.map(\.reason), [.unsafePath])
        XCTAssertTrue(gitlink.blockers[0].detail.contains(entry.licenseTextPath))
    }

    private func licensePolicyLaneExecution(
        files: [String: Data],
        symbolicLinks: [String: String] = [:],
        gitLinks: [String: String] = [:]
    ) throws -> ReleaseQualificationLaneExecution {
        let root = try makeSafeCheckSnapshotRepository(
            files: files,
            symbolicLinks: symbolicLinks,
            gitLinks: gitLinks
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "license-policy"
            }
        )
        return try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )
    }

    func testSecretScanLaneIgnoresConcurrentLivePathSwapAfterCommitBlobRead() throws {
        let root = try makeSafeCheckSnapshotRepository(
            files: ["README.md": Data("clean committed source\n".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = "AKIA" + String(repeating: "C", count: 16)
        let replacement = Data((credential + "\n").utf8)
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "secret-scan"
            }
        )

        let execution = try ReleaseQualificationLocalLaneRunner(
            sourceSnapshotRunner: ReleaseQualificationMutatingSnapshotRunner(
                sourceRoot: root,
                replacement: replacement
            )
        ).run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )

        XCTAssertEqual(execution.status, .passed)
        XCTAssertTrue(execution.failures.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("README.md")),
            replacement
        )
    }

    func testLocalLaneRunnerExecutesExactlyFourCommittedSafeLocalProviders() throws {
        let executable = Set([
            "dependency-lock-integrity",
            "documentation-source-contracts",
            "license-policy",
            "secret-scan",
        ])
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for lane in ReleaseQualificationDefaultRegistry.registry.lanes
            where !executable.contains(lane.id) {
            let execution = try ReleaseQualificationLocalLaneRunner().run(
                lane: lane,
                sourceRoot: root,
                sourceCommit: ReleaseQualificationTestSupport.commit
            )
            XCTAssertEqual(execution.status, .blocked, lane.id)
            XCTAssertEqual(execution.blockers.map(\.reason), [.missingExplicitAuthority], lane.id)
            XCTAssertTrue(execution.commands.isEmpty, lane.id)
            XCTAssertTrue(execution.failures.isEmpty, lane.id)
        }

        let committed = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "secret-scan"
            }
        )
        let forged = ReleaseQualificationLane(
            id: committed.id,
            kind: committed.kind,
            target: committed.target + " forged",
            executionMode: committed.executionMode,
            authority: committed.authority,
            requiredEvidenceClasses: committed.requiredEvidenceClasses,
            budget: committed.budget,
            corpus: committed.corpus,
            exclusions: committed.exclusions
        )
        let forgedExecution = try ReleaseQualificationLocalLaneRunner().run(
            lane: forged,
            sourceRoot: root,
            sourceCommit: ReleaseQualificationTestSupport.commit
        )
        XCTAssertEqual(forgedExecution.status, .blocked)
        XCTAssertEqual(forgedExecution.blockers.map(\.reason), [.missingExplicitAuthority])
        XCTAssertTrue(forgedExecution.commands.isEmpty)
    }

    func testDocumentationLaneRecordsOnlyBoundedCommandEvidence() throws {
        let root = ReleaseQualificationTestSupport.repositoryRoot()
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "documentation-source-contracts"
            }
        )
        let runner = ReleaseQualificationLocalLaneRunner(
            commandRunner: ReleaseQualificationFixedCommandRunner(
                result: ReleaseQualificationCommandResult(
                    exitStatus: 0,
                    standardOutput: Data("private command output".utf8),
                    standardError: Data(),
                    durationMilliseconds: 42
                )
            ),
            pythonLocator: ReleaseQualificationFixedPythonLocator(path: "/usr/bin/python3")
        )

        let execution = try runner.run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )

        XCTAssertEqual(execution.status, .passed)
        XCTAssertTrue(execution.commands.contains {
            $0.identity.purpose == "snapshot committed documentation input names"
        })
        XCTAssertTrue(execution.commands.contains {
            $0.identity.purpose.hasPrefix(
                "snapshot committed documentation input bytes request-sha256="
            )
        })
        let validators = execution.commands.filter {
            $0.identity.purpose.hasPrefix("validate ")
        }
        XCTAssertEqual(validators.count, 2)
        guard validators.count == 2 else { return }
        XCTAssertEqual(
            validators[0].identity.arguments.suffix(2),
            ["README.md", "docs"]
        )
        XCTAssertTrue(validators[0].identity.arguments.contains {
            $0 == root.appendingPathComponent("scripts/check-doc-links.py").path
        })
        XCTAssertTrue(validators[1].identity.arguments.contains {
            $0 == root.appendingPathComponent("scripts/check-current-truth.py").path
        })
        XCTAssertTrue(validators[0].identity.arguments.contains {
            $0 == "feec8f5d501dcce89dcc6ee2b5b155dfd9b1dbb4408efb02399f9b2adfebf588"
        })
        XCTAssertTrue(validators[1].identity.arguments.contains {
            $0 == "211b1e1716334b11aeac5d399ec99d68834ece7151f9dc0da05cb76f358dcfd4"
        })
        XCTAssertEqual(validators[0].durationMilliseconds, 42)
        XCTAssertEqual(validators[0].standardOutputBytes, 22)
        XCTAssertTrue(execution.blockers.isEmpty)
        XCTAssertTrue(execution.failures.isEmpty)
    }

    func testDocumentationLaneExecutesImmutableCommitSnapshotAfterLiveSourceSwap() throws {
        let root = try makeDocumentationSnapshotRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalREADME = try Data(
            contentsOf: root.appendingPathComponent("README.md")
        )
        let replacement = Data("transient attacker replacement\n".utf8)
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "documentation-source-contracts"
            }
        )
        let runner = ReleaseQualificationLocalLaneRunner(
            sourceSnapshotRunner: ReleaseQualificationMutatingSnapshotRunner(
                sourceRoot: root,
                replacement: replacement
            )
        )

        let execution = try runner.run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )

        XCTAssertEqual(execution.status, .passed)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("README.md")),
            replacement
        )
        XCTAssertNotEqual(originalREADME, replacement)
        XCTAssertEqual(
            execution.commands.filter {
                $0.identity.purpose.hasPrefix("validate ")
            }.map(\.exitStatus),
            [0, 0]
        )
    }

    func testDocumentationLaneFailsClosedWhenProviderScriptIsMissing() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "documentation-source-contracts"
            }
        )

        let execution = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: ReleaseQualificationTestSupport.commit
        )

        XCTAssertEqual(execution.status, .blocked)
        XCTAssertTrue(execution.commands.isEmpty)
        XCTAssertEqual(execution.blockers.map(\.reason), [.dependencyUnavailable])
    }

    func testDocumentationLanePreservesFirstObservationWhenSecondCommandTimesOut() throws {
        let root = ReleaseQualificationTestSupport.repositoryRoot()
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "documentation-source-contracts"
            }
        )
        let runner = ReleaseQualificationLocalLaneRunner(
            commandRunner: ReleaseQualificationSecondCommandTimeoutRunner(),
            pythonLocator: ReleaseQualificationFixedPythonLocator(path: "/usr/bin/python3")
        )

        let execution = try runner.run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: try releaseQualificationRepositoryCommit(root)
        )

        XCTAssertEqual(execution.status, .blocked)
        let validators = execution.commands.filter {
            $0.identity.purpose.hasPrefix("validate ")
        }
        XCTAssertEqual(validators.count, 1)
        guard validators.count == 1 else { return }
        XCTAssertEqual(
            validators[0].identity.arguments.suffix(2),
            ["README.md", "docs"]
        )
        XCTAssertEqual(execution.blockers.map(\.reason), [.unavailableFact])
    }

    func testDocumentationLaneRejectsTamperedProviderBeforeCommandExecution() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scripts,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for name in ["check-doc-links.py", "check-current-truth.py"] {
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: scripts.appendingPathComponent(name).path,
                    contents: Data("raise SystemExit(0)\n".utf8),
                    attributes: [.posixPermissions: 0o600]
                )
            )
        }
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "documentation-source-contracts"
            }
        )

        let execution = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: ReleaseQualificationTestSupport.commit
        )

        XCTAssertEqual(execution.status, .blocked)
        XCTAssertTrue(execution.commands.isEmpty)
        XCTAssertEqual(execution.blockers.map(\.reason), [.corpusMismatch])
    }

    func testDocumentationLaneRejectsProviderSymlinkBeforeCommandExecution() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scripts,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let repositoryScripts = ReleaseQualificationTestSupport.repositoryRoot()
            .appendingPathComponent("scripts")
        try FileManager.default.createSymbolicLink(
            at: scripts.appendingPathComponent("check-doc-links.py"),
            withDestinationURL: repositoryScripts.appendingPathComponent("check-doc-links.py")
        )
        try FileManager.default.createSymbolicLink(
            at: scripts.appendingPathComponent("check-current-truth.py"),
            withDestinationURL: repositoryScripts.appendingPathComponent("check-current-truth.py")
        )
        let lane = try XCTUnwrap(
            ReleaseQualificationDefaultRegistry.registry.lanes.first {
                $0.id == "documentation-source-contracts"
            }
        )

        let execution = try ReleaseQualificationLocalLaneRunner().run(
            lane: lane,
            sourceRoot: root,
            sourceCommit: ReleaseQualificationTestSupport.commit
        )

        XCTAssertEqual(execution.status, .blocked)
        XCTAssertTrue(execution.commands.isEmpty)
        XCTAssertEqual(execution.blockers.map(\.reason), [.dependencyUnavailable])
    }
}

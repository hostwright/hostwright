import Darwin
import Foundation
import HostwrightCore

public enum DistributionPackageVersion {
    public static func make(from semanticVersion: String) throws -> String {
        _ = try DistributionSemanticVersion(parsing: semanticVersion)
        let withoutBuild = semanticVersion.split(separator: "+", maxSplits: 1).first.map(String.init)
            ?? semanticVersion
        let components = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
        let core = components[0]
        guard components.count == 2 else { return core }
        let prerelease = components[1]
        if prerelease == "dev" { return core + ".0" }
        let identifiers = prerelease.split(separator: ".", omittingEmptySubsequences: false)
        guard identifiers.count == 2,
              identifiers[0] == "dev",
              let qualification = identifiers.last,
              !qualification.isEmpty,
              qualification.allSatisfy(\.isNumber),
              qualification == "0" || !qualification.hasPrefix("0") else {
            throw DistributionError.invalidArguments(
                "Installer package versions support stable semantic versions or a dev.N prerelease."
            )
        }
        return core + "." + qualification
    }

    public static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
                && (part == "0" || !part.hasPrefix("0"))
        }
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard isValid(lhs), isValid(rhs) else { return .orderedSame }
        let left = lhs.split(separator: ".").map(String.init)
        let right = rhs.split(separator: ".").map(String.init)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : "0"
            let r = index < right.count ? right[index] : "0"
            if l.count != r.count { return l.count < r.count ? .orderedAscending : .orderedDescending }
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

enum DistributionPackageScripts {
    static func postinstall(packageVersion: String, teamIdentifier: String) -> String {
        """
        #!/bin/sh
        set -eu
        exec '/Library/Application Support/Hostwright/InstallerPayload/bin/hostwright-dist' package-apply \\
          --staged-root '/Library/Application Support/Hostwright/InstallerPayload' \\
          --prefix '/usr/local' \\
          --package-id 'dev.hostwright.cli' \\
          --package-version '\(packageVersion)' \\
          --team-id '\(teamIdentifier)' \\
          --output json
        """ + "\n"
    }
}

package enum DistributionPackagePolicy {
    package static let removeDataUnsupportedMessage =
        "Package-managed installations support only --data-policy preserve because Hostwright does not infer or search for per-user state databases."
    package static let preserveConfirmationUnsupportedMessage =
        "package-uninstall --data-policy preserve does not accept --confirmation."
}

public struct DistributionPackageReceipt: Codable, Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let installLocation: String
    public let volume: String

    public init(identifier: String, version: String, installLocation: String, volume: String) {
        self.identifier = identifier
        self.version = version
        self.installLocation = installLocation
        self.volume = volume
    }

    public func validate() throws {
        guard identifier == DistributionLayout.packageIdentifier,
              DistributionPackageVersion.isValid(version),
              installLocation == "/",
              volume == "/" else {
            throw DistributionError.invalidArtifact("Apple Installer receipt identity or location is invalid")
        }
    }
}

public enum DistributionPackageReceiptParser {
    public static func parse(_ data: Data) throws -> DistributionPackageReceipt {
        guard data.count <= 1024 * 1024,
              let object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let identifier = object["pkgid"] as? String,
              let version = object["pkg-version"] as? String,
              let installLocation = object["install-location"] as? String,
              let volume = object["volume"] as? String else {
            throw DistributionError.invalidArtifact("Apple Installer receipt plist is malformed")
        }
        let receipt = DistributionPackageReceipt(
            identifier: identifier,
            version: version,
            installLocation: installLocation,
            volume: volume
        )
        try receipt.validate()
        return receipt
    }
}

struct DistributionPackageReceiptController: Sendable {
    let runner: DistributionProcessRunner
    let executablePath: String
    let stagingRoot: URL
    let stagingOwnerUID: uid_t

    init(
        runner: DistributionProcessRunner = DistributionProcessRunner(),
        executablePath: String = "/usr/sbin/pkgutil",
        stagingRoot: URL = URL(fileURLWithPath: DistributionLayout.packageStagingPath),
        stagingOwnerUID: uid_t = 0
    ) {
        self.runner = runner
        self.executablePath = executablePath
        self.stagingRoot = stagingRoot.standardizedFileURL
        self.stagingOwnerUID = stagingOwnerUID
    }

    func receipt(
        identifier: String,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionPackageReceipt? {
        guard identifier == DistributionLayout.packageIdentifier else {
            throw DistributionError.invalidArguments("Unsupported Apple Installer package identifier.")
        }
        let inventory = try runner.run(
            executablePath: executablePath,
            arguments: ["--pkgs"],
            label: "list Apple Installer receipts",
            timeoutSeconds: 30,
            cancellation: cancellation
        )
        let identifiers = Set(
            inventory.standardOutput.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        )
        guard identifiers.contains(identifier) else { return nil }
        let result = try runner.run(
            executablePath: executablePath,
            arguments: ["--pkg-info-plist", identifier],
            label: "read exact Hostwright package receipt",
            timeoutSeconds: 30,
            cancellation: cancellation
        )
        guard let data = result.standardOutput.data(using: .utf8) else {
            throw DistributionError.invalidArtifact("Apple Installer receipt output is not UTF-8")
        }
        let receipt = try DistributionPackageReceiptParser.parse(data)
        guard receipt.identifier == identifier else {
            throw DistributionError.invalidArtifact("Apple Installer returned a different package receipt")
        }
        return receipt
    }

    func forget(
        identifier: String,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard identifier == DistributionLayout.packageIdentifier else {
            throw DistributionError.invalidArguments("Unsupported Apple Installer package identifier.")
        }
        _ = try runner.run(
            executablePath: executablePath,
            arguments: ["--forget", identifier],
            label: "forget exact Hostwright package receipt",
            timeoutSeconds: 30,
            cancellation: cancellation
        )
    }
}

public struct DistributionPackageApplyResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let operation: DistributionLifecycleOperation
    public let receipt: DistributionPackageReceipt
    public let signerTeamIdentifier: String
    public let status: DistributionInstallationStatus

    init(
        operation: DistributionLifecycleOperation,
        receipt: DistributionPackageReceipt,
        signerTeamIdentifier: String,
        status: DistributionInstallationStatus
    ) {
        self.schemaVersion = 1
        self.kind = "distributionPackageApply"
        self.operation = operation
        self.receipt = receipt
        self.signerTeamIdentifier = signerTeamIdentifier
        self.status = status
    }
}

public struct DistributionPackageUninstallResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let packageIdentifier: String
    public let receiptCleanupPending: Bool
    public let lifecycle: DistributionUninstallResult

    init(lifecycle: DistributionUninstallResult) {
        self.schemaVersion = 1
        self.kind = "distributionPackageUninstall"
        self.packageIdentifier = DistributionLayout.packageIdentifier
        self.receiptCleanupPending = false
        self.lifecycle = lifecycle
    }
}

public struct DistributionPackageLifecycle: Sendable {
    private let runner: DistributionProcessRunner
    private let receiptController: DistributionPackageReceiptController
    private let lifecycle: DistributionInstalledLifecycle
    private let expectedPrefix: URL
    private let expectedStagingRoot: URL
    private let expectedOwnerUID: uid_t
    private let effectiveUserID: uid_t
    private let verifyExecutableSignatures: Bool

    public init() {
        let runner = DistributionProcessRunner()
        let receipts = DistributionPackageReceiptController(runner: runner)
        self.runner = runner
        self.receiptController = receipts
        self.lifecycle = DistributionInstalledLifecycle(packageReceiptController: receipts)
        self.expectedPrefix = URL(fileURLWithPath: DistributionLayout.packageInstallPrefix)
        self.expectedStagingRoot = URL(fileURLWithPath: DistributionLayout.packageStagingPath)
        self.expectedOwnerUID = 0
        self.effectiveUserID = geteuid()
        self.verifyExecutableSignatures = true
    }

    init(
        runner: DistributionProcessRunner = DistributionProcessRunner(),
        receiptController: DistributionPackageReceiptController,
        lifecycle: DistributionInstalledLifecycle? = nil,
        expectedPrefix: URL,
        expectedStagingRoot: URL,
        expectedOwnerUID: uid_t,
        effectiveUserID: uid_t,
        verifyExecutableSignatures: Bool
    ) {
        self.runner = runner
        self.receiptController = receiptController
        self.lifecycle = lifecycle
            ?? DistributionInstalledLifecycle(packageReceiptController: receiptController)
        self.expectedPrefix = expectedPrefix.standardizedFileURL
        self.expectedStagingRoot = expectedStagingRoot.standardizedFileURL
        self.expectedOwnerUID = expectedOwnerUID
        self.effectiveUserID = effectiveUserID
        self.verifyExecutableSignatures = verifyExecutableSignatures
    }

    public func apply(
        stagedRoot: URL,
        prefix: URL,
        packageIdentifier: String,
        packageVersion: String,
        teamIdentifier: String,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionPackageApplyResult {
        guard teamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw DistributionError.invalidArguments(
                "package-apply requires an exact 10-character Developer Team ID."
            )
        }
        try requireElevatedAuthority()
        try requireExactLocations(stagedRoot: stagedRoot, prefix: prefix)
        guard packageIdentifier == DistributionLayout.packageIdentifier,
              DistributionPackageVersion.isValid(packageVersion) else {
            throw DistributionError.invalidArtifact(
                "package-apply requires the exact Hostwright package identity"
            )
        }
        let receipt = DistributionPackageReceipt(
            identifier: packageIdentifier,
            version: packageVersion,
            installLocation: "/",
            volume: "/"
        )
        try receipt.validate()
        let verified = try verifyStagedPayload(
            stagedRoot,
            receipt: receipt,
            cancellation: cancellation
        )
        guard verified.teamIdentifier == teamIdentifier else {
            throw DistributionError.invalidArtifact(
                "staged executable signer team does not match the package trust policy"
            )
        }
        let inspection = try lifecycle.inspectForPackageApply(prefix: prefix)
        let operation = try requiredOperation(
            inspection: inspection,
            manifest: verified.manifest
        )
        try requireValidPriorReceipt(
            inspection: inspection,
            operation: operation,
            candidateManifest: verified.manifest,
            targetReceipt: receipt,
            cancellation: cancellation
        )
        let origin = DistributionPackageOrigin(
            packageIdentifier: receipt.identifier,
            packageVersion: receipt.version,
            mostRecentPackageReceiptVersion: receipt.version
        )
        try origin.validate()
        let status = try lifecycle.installPackage(
            manifest: verified.manifest,
            sourceRoot: stagedRoot,
            prefix: prefix,
            requiredOperation: operation,
            packageOrigin: origin,
            cancellation: cancellation
        )
        return DistributionPackageApplyResult(
            operation: operation,
            receipt: receipt,
            signerTeamIdentifier: verified.teamIdentifier,
            status: status
        )
    }

    public func uninstall(
        prefix: URL,
        dataPolicy: DistributionUninstallDataPolicy,
        confirmationToken: String? = nil,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionPackageUninstallResult {
        try requireElevatedAuthority()
        guard prefix.standardizedFileURL.path == expectedPrefix.path else {
            throw DistributionError.unsafePath("package-uninstall requires the exact /usr/local prefix.")
        }
        guard dataPolicy == .preserve else {
            throw DistributionError.invalidArguments(
                DistributionPackagePolicy.removeDataUnsupportedMessage
            )
        }
        guard confirmationToken == nil else {
            throw DistributionError.invalidArguments(
                DistributionPackagePolicy.preserveConfirmationUnsupportedMessage
            )
        }
        let inspection = try lifecycle.inspect(prefix: prefix)
        guard inspection.readiness == .ready,
              let status = inspection.status,
              let origin = status.packageOrigin,
              !origin.pendingReceiptCleanup,
              let receipt = try receiptController.receipt(
                identifier: origin.packageIdentifier,
                cancellation: cancellation
              ),
              receipt.version == origin.mostRecentPackageReceiptVersion else {
            throw DistributionError.installOwnershipMismatch(
                "package lifecycle status or receipt"
            )
        }
        _ = try verifyStagedPayload(
            expectedStagingRoot,
            receipt: receipt,
            cancellation: cancellation
        )
        let result = try lifecycle.uninstallPackage(
            prefix: prefix,
            dataPolicy: dataPolicy,
            confirmationToken: confirmationToken,
            cancellation: cancellation
        )
        return DistributionPackageUninstallResult(lifecycle: result)
    }

    private func requiredOperation(
        inspection: DistributionLifecycleInspection,
        manifest: DistributionArtifactManifest
    ) throws -> DistributionLifecycleOperation {
        switch inspection.readiness {
        case .notInstalled:
            return .install
        case .recoveryRequired:
            throw DistributionError.lifecycleFailed(
                "package apply requires hostwright-dist recover before mutation"
            )
        case .ready:
            guard let installed = inspection.status?.installedManifest else {
                throw DistributionError.lifecycleFailed("ready lifecycle inspection omitted status")
            }
            return switch try DistributionVersionTransition.classify(
                installedVersion: installed.packageVersion,
                installedCommit: installed.sourceCommit,
                candidateVersion: manifest.packageVersion,
                candidateCommit: manifest.sourceCommit
            ) {
            case .upgrade: .upgrade
            case .repair: .repair
            }
        }
    }

    private func requireValidPriorReceipt(
        inspection: DistributionLifecycleInspection,
        operation: DistributionLifecycleOperation,
        candidateManifest: DistributionArtifactManifest,
        targetReceipt: DistributionPackageReceipt,
        cancellation: SecureSubprocessCancellation
    ) throws {
        let observed = try receiptController.receipt(
            identifier: targetReceipt.identifier,
            cancellation: cancellation
        )
        guard let status = inspection.status else {
            guard observed == nil else {
                throw DistributionError.installOwnershipMismatch("package receipt")
            }
            return
        }
        guard let origin = status.packageOrigin else {
            guard observed == nil else {
                throw DistributionError.installOwnershipMismatch("package receipt")
            }
            return
        }
        if observed?.identifier == origin.packageIdentifier,
           observed?.version == origin.mostRecentPackageReceiptVersion {
            return
        }
        let candidateInstallManifest = DistributionInstallManifest(
            artifact: candidateManifest,
            createdDirectories: status.installedManifest.createdDirectories
        )
        guard operation == .repair,
              status.installedManifest == candidateInstallManifest,
              !origin.pendingReceiptCleanup,
              origin.packageIdentifier == targetReceipt.identifier,
              origin.packageVersion == targetReceipt.version,
              origin.mostRecentPackageReceiptVersion == targetReceipt.version else {
            throw DistributionError.installOwnershipMismatch("package receipt")
        }
    }

    private func requireElevatedAuthority() throws {
        guard effectiveUserID == 0 else {
            throw DistributionError.invalidArguments(
                "Package lifecycle commands require elevated authority."
            )
        }
    }

    private func requireExactLocations(stagedRoot: URL, prefix: URL) throws {
        guard prefix.standardizedFileURL.resolvingSymlinksInPath().path == expectedPrefix.path,
              stagedRoot.standardizedFileURL.resolvingSymlinksInPath().path
                == expectedStagingRoot.path else {
            throw DistributionError.unsafePath(
                "Package lifecycle paths must be the exact package staging root and /usr/local prefix."
            )
        }
    }

    private func verifyStagedPayload(
        _ root: URL,
        receipt: DistributionPackageReceipt,
        cancellation: SecureSubprocessCancellation
    ) throws -> (manifest: DistributionArtifactManifest, teamIdentifier: String) {
        try receipt.validate()
        guard try DistributionFileSystem.isDirectoryNonSymlink(root),
              try DistributionFileSystem.mode(of: root) == 0o700 else {
            throw DistributionError.unsafePath("Package staging root must be a private directory.")
        }
        var rootMetadata = stat()
        guard lstat(root.path, &rootMetadata) == 0,
              rootMetadata.st_uid == expectedOwnerUID,
              rootMetadata.st_nlink >= 2 else {
            throw DistributionError.unsafePath("Package staging root ownership is invalid.")
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                atPath: root.path,
                role: "package staging root"
            )
        } catch {
            throw DistributionError.unsafePath("Package staging root grants access through an ACL.")
        }
        let manifest = try DistributionJSON.decode(
            DistributionArtifactManifest.self,
            from: root.appendingPathComponent(DistributionLayout.manifestFileName)
        )
        try manifest.validate()
        guard try DistributionPackageVersion.make(from: manifest.packageVersion) == receipt.version else {
            throw DistributionError.invalidArtifact(
                "package receipt version does not match the staged manifest"
            )
        }
        let expectedFiles = Set(
            manifest.files.map(\.path) + [DistributionLayout.manifestFileName]
        )
        let actual = try regularFileInventory(root)
        guard Set(actual) == expectedFiles, actual.count == expectedFiles.count else {
            throw DistributionError.invalidArtifact(
                "package staging payload contains unexpected or missing files"
            )
        }
        for file in manifest.files {
            guard !cancellation.isCancelled else {
                throw DistributionError.commandCancelled("verify package staging payload")
            }
            let url = root.appendingPathComponent(file.path)
            guard try DistributionHash.sha256(fileURL: url, cancellation: cancellation) == file.sha256,
                  try DistributionFileSystem.size(of: url) == file.sizeBytes,
                  try DistributionFileSystem.mode(of: url) == file.mode,
                  try singleLinkOwnedFile(url) else {
                throw DistributionError.checksumMismatch(file.path)
            }
        }
        let team = try verifySignatures(
            root: root,
            cancellation: cancellation
        )
        return (manifest, team)
    }

    private func verifySignatures(
        root: URL,
        cancellation: SecureSubprocessCancellation
    ) throws -> String {
        guard verifyExecutableSignatures else { return "TESTTEAM01" }
        var teamIdentifier: String?
        for path in DistributionLayout.shippedBinaryPaths {
            let binary = root.appendingPathComponent(path)
            _ = try runner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "--verbose=4", binary.path],
                label: "verify staged package executable signature",
                timeoutSeconds: 30,
                cancellation: cancellation
            )
            let details = try runner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--display", "--verbose=4", binary.path],
                label: "inspect staged package executable signature",
                timeoutSeconds: 30,
                cancellation: cancellation
            )
            let text = details.standardOutput + details.standardError
            guard text.contains("Authority=Developer ID Application: "),
                  text.lowercased().contains("runtime"),
                  let observed = text.firstMatch(of: /TeamIdentifier=([A-Z0-9]{10})/) else {
                throw DistributionError.invalidArtifact(
                    "staged executable lacks the required Developer ID hardened-runtime signature"
                )
            }
            let current = String(observed.output.1)
            if let teamIdentifier, current != teamIdentifier {
                throw DistributionError.invalidArtifact(
                    "staged executables use different Developer ID teams"
                )
            }
            teamIdentifier = current
        }
        guard let teamIdentifier else {
            throw DistributionError.invalidArtifact("package contains no signed executables")
        }
        return teamIdentifier
    }

    private func regularFileInventory(_ root: URL) throws -> [String] {
        var files: [String] = []
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() {
            guard DistributionPathPolicy.isSafeRelativePath(path) else {
                throw DistributionError.unsafePath("Package staging contains an unsafe path.")
            }
            let url = root.appendingPathComponent(path)
            if try DistributionFileSystem.isRegularNonSymlink(url) {
                files.append(path)
            } else if try DistributionFileSystem.isDirectoryNonSymlink(url) {
                continue
            } else {
                throw DistributionError.unsafePath("Package staging contains a link or special file.")
            }
        }
        return files
    }

    private func singleLinkOwnedFile(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == expectedOwnerUID
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o7000 == 0
    }
}

enum DistributionPackageStagingCleanup {
    static func finalize(
        status: DistributionInstallationStatus,
        receiptController: DistributionPackageReceiptController,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard let origin = status.packageOrigin, origin.pendingReceiptCleanup else { return }
        try origin.validate()
        if let receipt = try receiptController.receipt(
            identifier: origin.packageIdentifier,
            cancellation: cancellation
        ) {
            guard receipt.version == origin.mostRecentPackageReceiptVersion else {
                throw DistributionError.installOwnershipMismatch("package receipt version")
            }
            try receiptController.forget(
                identifier: origin.packageIdentifier,
                cancellation: cancellation
            )
        }
        try removeExactStagingPayload(
            expectedReceiptVersion: origin.mostRecentPackageReceiptVersion,
            root: receiptController.stagingRoot,
            expectedOwnerUID: receiptController.stagingOwnerUID,
            cancellation: cancellation
        )
    }

    private static func removeExactStagingPayload(
        expectedReceiptVersion: String,
        root: URL,
        expectedOwnerUID: uid_t,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard DistributionFileSystem.entryExists(root) else { return }
        guard try DistributionFileSystem.isDirectoryNonSymlink(root),
              try DistributionFileSystem.mode(of: root) == 0o700 else {
            throw DistributionError.unsafePath("Package staging cleanup root is unsafe.")
        }
        var rootMetadata = stat()
        guard lstat(root.path, &rootMetadata) == 0,
              rootMetadata.st_uid == expectedOwnerUID else {
            throw DistributionError.unsafePath(
                "Package staging cleanup root ownership is invalid."
            )
        }
        let manifestURL = root.appendingPathComponent(DistributionLayout.manifestFileName)
        if DistributionFileSystem.entryExists(manifestURL) {
            let manifest = try DistributionJSON.decode(
                DistributionArtifactManifest.self,
                from: manifestURL
            )
            guard try DistributionPackageVersion.make(from: manifest.packageVersion)
                == expectedReceiptVersion else {
                throw DistributionError.installOwnershipMismatch("package staging manifest")
            }
            let allowedFiles = Set(
                manifest.files.map(\.path) + [DistributionLayout.manifestFileName]
            )
            let entries = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            for entry in entries {
                let url = root.appendingPathComponent(entry)
                if try DistributionFileSystem.isRegularNonSymlink(url) {
                    guard allowedFiles.contains(entry) else {
                        throw DistributionError.unsafePath(
                            "Package staging cleanup found an unmanaged file."
                        )
                    }
                } else if try DistributionFileSystem.isDirectoryNonSymlink(url) {
                    continue
                } else {
                    throw DistributionError.unsafePath(
                        "Package staging cleanup found a link or special file."
                    )
                }
            }
            for file in manifest.files.sorted(by: { lhs, rhs in
                if lhs.path == "bin/hostwright-dist" { return false }
                if rhs.path == "bin/hostwright-dist" { return true }
                return lhs.path < rhs.path
            }) {
                guard !cancellation.isCancelled else {
                    throw DistributionError.commandCancelled("remove package staging payload")
                }
                let url = root.appendingPathComponent(file.path)
                guard try !DistributionFileSystem.entryExists(url)
                    || exactFileMatches(file, url: url, expectedOwnerUID: expectedOwnerUID) else {
                    throw DistributionError.installOwnershipMismatch(file.path)
                }
                if DistributionFileSystem.entryExists(url) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            try FileManager.default.removeItem(at: manifestURL)
        } else {
            let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter {
                let url = root.appendingPathComponent($0)
                return (try? DistributionFileSystem.isRegularNonSymlink(url)) == true
            }
            guard files.isEmpty else {
                throw DistributionError.unsafePath(
                    "Package staging cleanup is missing its manifest but still contains files."
                )
            }
        }
        try removeKnownDirectories(root)
    }

    private static func exactFileMatches(
        _ file: DistributionFileRecord,
        url: URL,
        expectedOwnerUID: uid_t
    ) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == expectedOwnerUID,
              metadata.st_nlink == 1,
              Int(metadata.st_mode & 0o777) == file.mode,
              Int(metadata.st_size) == file.sizeBytes else { return false }
        return try DistributionHash.sha256(fileURL: url) == file.sha256
    }

    private static func removeKnownDirectories(_ root: URL) throws {
        let directories = Set(DistributionLayout.payloadModes.keys.flatMap { path -> [String] in
            let components = path.split(separator: "/").map(String.init)
            var result: [String] = []
            var current = ""
            for component in components.dropLast() {
                current = current.isEmpty ? component : "\(current)/\(component)"
                result.append(current)
            }
            return result
        })
        for path in directories.sorted(by: { $0.count > $1.count }) {
            let directory = root.appendingPathComponent(path, isDirectory: true)
            if DistributionFileSystem.entryExists(directory),
               try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
                try FileManager.default.removeItem(at: directory)
            }
        }
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw DistributionError.unsafePath("Package staging cleanup found unmanaged content.")
        }
        try FileManager.default.removeItem(at: root)
        let parent = root.deletingLastPathComponent()
        if try DistributionFileSystem.isDirectoryNonSymlink(parent),
           try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty {
            try FileManager.default.removeItem(at: parent)
        }
    }
}

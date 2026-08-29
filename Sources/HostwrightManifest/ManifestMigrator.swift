import Foundation
import HostwrightCore

public enum ManifestMigrationChange: Equatable, Sendable {
    case insertVersion(Int)
    case replaceVersion(from: Int, to: Int)
    case migrateLegacyResources
    case migrateLegacyHealth

    public var description: String {
        switch self {
        case .insertVersion(let version):
            return "Declare manifest version \(version)."
        case .replaceVersion(let source, let target):
            return "Replace manifest version \(source) with \(target)."
        case .migrateLegacyResources:
            return "Replace legacy flat resource fields with explicit requests and limits."
        case .migrateLegacyHealth:
            return "Replace legacy health checks with typed liveness probes."
        }
    }
}

public struct ManifestMigrationPreview: Equatable, Sendable {
    public let sourceVersion: Int
    public let targetVersion: Int
    public let migratedManifest: String
    public let changes: [ManifestMigrationChange]

    public init(
        sourceVersion: Int,
        targetVersion: Int,
        migratedManifest: String,
        changes: [ManifestMigrationChange]
    ) {
        self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion
        self.migratedManifest = migratedManifest
        self.changes = changes
    }
}

public enum ManifestMigrator {
    public static func previewV3(_ source: String) throws -> ManifestMigrationPreview {
        let parsedResult = try ManifestParser.parseForMigrationPreview(source)
        let parsed = parsedResult.manifest
        let sourceVersion = parsed.version ?? HostwrightManifest.legacyVersion
        let targetVersion = HostwrightManifest.currentVersion

        guard sourceVersion <= targetVersion else {
            throw ManifestParseError.failed([
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(sourceVersion) is newer than supported version \(targetVersion). Upgrade requires a newer Hostwright release."
                )
            ])
        }
        guard [HostwrightManifest.legacyVersion, 2, targetVersion].contains(sourceVersion) else {
            throw ManifestParseError.failed([
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(sourceVersion) has no supported migration path. Only versions 1 and 2 can be previewed for version \(targetVersion)."
                )
            ])
        }
        if sourceVersion == targetVersion && parsedResult.usedLegacyFlatResources {
            throw ManifestParseError.failed([
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(targetVersion) must use nested resources.requests and resources.limits; flat resources are legacy input only.",
                    path: parsedResult.legacyFlatResourcePaths.first
                )
            ])
        }
        if let service = parsed.services.first(where: { $0.resources == nil }) {
            throw ManifestParseError.failed([
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(service.name)' requires an explicit CPU and memory requests/limits contract; migration cannot infer capacity. Add resources.requests and resources.limits manually before retrying.",
                    path: "$.services.\(service.name).resources"
                )
            ])
        }

        var migratedManifest: String
        var changes: [ManifestMigrationChange]
        switch parsed.version {
        case .none:
            let newline = source.contains("\r\n") ? "\r\n" : "\n"
            migratedManifest = "version: \(targetVersion)\(newline)" + source
            changes = [.insertVersion(targetVersion)]
        case .some(targetVersion):
            migratedManifest = source
            changes = []
        case .some(let version):
            migratedManifest = try replaceTopLevelVersion(in: source, from: version, to: targetVersion)
            changes = [.replaceVersion(from: version, to: targetVersion)]
        }

        let needsResourceConversion = sourceVersion < targetVersion && parsedResult.usedLegacyFlatResources
        let needsHealthConversion = containsLegacyHealth(source)
        if needsResourceConversion || needsHealthConversion {
            var migrated = parsed
            migrated.version = targetVersion
            migratedManifest = try ManifestCanonicalEncoder.encode(migrated)
            if needsResourceConversion {
                changes.append(.migrateLegacyResources)
            }
            if needsHealthConversion {
                changes.append(.migrateLegacyHealth)
            }
        }

        _ = try ManifestValidator.validated(migratedManifest)
        return ManifestMigrationPreview(
            sourceVersion: sourceVersion,
            targetVersion: targetVersion,
            migratedManifest: migratedManifest,
            changes: changes
        )
    }

    private static func containsLegacyHealth(_ source: String) -> Bool {
        source.range(
            of: #"(?m)^    health:[ \t]*(?:#.*)?\r?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func replaceTopLevelVersion(in source: String, from: Int, to: Int) throws -> String {
        let pattern = "(?m)^version:[ \\t]*\(from)[ \\t]*(?=\\r?$)"
        guard let range = source.range(of: pattern, options: .regularExpression) else {
            throw ManifestParseError.failed([
                ManifestIssue(
                    code: .manifestParseFailed,
                    message: "Could not locate the parsed top-level manifest version for migration."
                )
            ])
        }
        var migrated = source
        migrated.replaceSubrange(range, with: "version: \(to)")
        return migrated
    }
}

import Foundation
import HostwrightCore
import HostwrightRegistry
import HostwrightRuntime

public enum LocalControlRequestParser {
    public static let maximumRequestBytes = 64 * 1_024

    private static let allowedKeys: Set<String> = [
        "apiVersion",
        "requestID",
        "operation",
        "project",
        "eventType",
        "service",
        "severity",
        "limit",
        "sort",
        "services",
        "dryRun",
        "confirmPlan",
        "runtimeProvider",
        "timeout",
        "parallelism",
        "imageOperation",
        "imageReferences",
        "imageTargetReference",
        "imageContextPath",
        "imageFilePath",
        "imageArchivePath",
        "imagePlatform",
        "imageOffline",
        "imageNoCache",
        "imageProgress",
        "imageMaximumBytes",
        "imageTargetBytes",
        "imageRetentionSeconds",
        "imageMaximumDeletions",
        "volumeOperation",
        "volumeIDs",
        "volumeResourceID",
        "volumeName",
        "volumeTargetVolumeID",
        "volumeReferenceID",
        "volumeOwner",
        "volumeOutputPath",
        "volumeKeyReference",
        "volumeRestoreTargets",
        "volumeIdempotencyKey",
        "volumeRemoteS3Endpoint",
        "volumeRemoteS3Bucket",
        "volumeRemoteS3Region",
        "volumeRemoteS3Prefix",
        "volumeRemoteS3AccessKeyReference",
        "volumeRemoteS3SecretKeyReference",
        "registryReferrerOperation",
        "registryServer",
        "registryRepository",
        "registrySubjectDigest",
        "registryArtifactType",
        "registryTargetServer",
        "registryTargetRepository",
        "registryDiscoveryID",
        "registryReferrerDigest",
        "registryLeaseID",
        "registryFencingToken",
        "registryOwnerID",
        "registryExpiresAt",
        "registryOperationGroupID",
        "registryOffline",
        "registryTrustOperation",
        "registrySBOMOperation",
        "registryVulnerabilityOperation",
        "registryProvenanceOperation",
        "registrySBOMArchivePath",
        "registrySBOMFormat",
        "registrySBOMOutputPath",
        "registryProvenanceArchivePath",
        "registryProvenanceBuildRecordPath",
        "registryProvenanceDescriptorDigest",
        "registryProvenanceReferrerDigest",
        "registryProvenanceSignerID",
        "registryProvenanceSigningKeyReference",
        "registrySubjectManifestPath",
        "registryCosignPath",
        "registryServiceName",
        "registryApprovalRecordPath",
        "registryExceptionID"
    ]
    private static let requiredKeys: Set<String> = ["apiVersion", "requestID", "operation"]

    public static func parse(_ data: Data) throws -> LocalControlRequest {
        guard !data.isEmpty, data.count <= maximumRequestBytes else {
            throw invalid("The local control request must be non-empty and no larger than 64 KiB.")
        }
        try StrictControlJSONObject.validate(
            data,
            allowedKeys: allowedKeys,
            requiredKeys: requiredKeys,
            role: "local control request"
        )

        let request: LocalControlRequest
        do {
            request = try JSONDecoder().decode(LocalControlRequest.self, from: data)
        } catch {
            throw invalid("The local control request has invalid field types or values.")
        }
        try validate(request)
        return request
    }

    static func validate(_ request: LocalControlRequest) throws {
        guard request.apiVersion == HostwrightContractVersions.controlAPI else {
            throw invalid("Local control API version \(request.apiVersion) is not supported.")
        }
        guard request.requestID.range(
            of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,63})$",
            options: .regularExpression
        ) != nil else {
            throw invalid("Local control requestID must contain 1-64 safe identifier characters.")
        }

        for value in [request.project, request.eventType, request.service].compactMap({ $0 }) {
            guard validFilter(value) else {
                throw invalid("Local control string filters must be non-empty bounded text without control characters.")
            }
        }
        if let severity = request.severity, !["info", "warning", "error"].contains(severity) {
            throw invalid("Local control event severity supports only info, warning, or error.")
        }
        if let sort = request.sort, !["asc", "desc"].contains(sort) {
            throw invalid("Local control event sort supports only asc or desc.")
        }
        if let limit = request.limit, !(1...1_000).contains(limit) {
            throw invalid("Local control event limit must be between 1 and 1000.")
        }
        if let services = request.services {
            guard !services.isEmpty,
                  services.count <= 256,
                  Set(services).count == services.count,
                  services.allSatisfy(validServiceName) else {
                throw invalid("Local control lifecycle services must contain 1-256 unique bounded identifiers.")
            }
        }
        if let dryRun = request.dryRun, !dryRun {
            throw invalid("Local control lifecycle dryRun, when present, must be true.")
        }
        if let confirmPlan = request.confirmPlan, !validSHA256(confirmPlan) {
            throw invalid("Local control lifecycle confirmPlan must be an exact lowercase SHA-256.")
        }
        if let runtimeProvider = request.runtimeProvider,
           !["auto", "apple-cli", "containerization"].contains(runtimeProvider) {
            throw invalid("Local control lifecycle runtimeProvider supports only auto, apple-cli, or containerization.")
        }
        if let timeout = request.timeout, !(1...86_400).contains(timeout) {
            throw invalid("Local control lifecycle timeout must be between 1 and 86400 seconds.")
        }
        if let parallelism = request.parallelism, !(1...32).contains(parallelism) {
            throw invalid("Local control lifecycle parallelism must be between 1 and 32.")
        }

        let hasEventOnlyFilters = request.eventType != nil || request.service != nil ||
            request.severity != nil || request.limit != nil || request.sort != nil
        let hasLifecycleFields = request.services != nil || request.dryRun != nil ||
            request.confirmPlan != nil || request.runtimeProvider != nil ||
            request.timeout != nil || request.parallelism != nil
        let hasImageFields = request.imageOperation != nil ||
            request.imageReferences != nil ||
            request.imageTargetReference != nil ||
            request.imageContextPath != nil ||
            request.imageFilePath != nil ||
            request.imageArchivePath != nil ||
            request.imagePlatform != nil ||
            request.imageOffline != nil ||
            request.imageNoCache != nil ||
            request.imageProgress != nil ||
            request.imageMaximumBytes != nil ||
            request.imageTargetBytes != nil ||
            request.imageRetentionSeconds != nil ||
            request.imageMaximumDeletions != nil
        let hasRegistryFields =
            request.registryReferrerOperation != nil ||
            request.registryServer != nil ||
            request.registryRepository != nil ||
            request.registrySubjectDigest != nil ||
            request.registryArtifactType != nil ||
            request.registryTargetServer != nil ||
            request.registryTargetRepository != nil ||
            request.registryDiscoveryID != nil ||
            request.registryReferrerDigest != nil ||
            request.registryLeaseID != nil ||
            request.registryFencingToken != nil ||
            request.registryOwnerID != nil ||
            request.registryExpiresAt != nil ||
            request.registryOperationGroupID != nil ||
            request.registryOffline != nil ||
            request.registryTrustOperation != nil ||
            request.registrySBOMOperation != nil ||
            request.registryVulnerabilityOperation != nil ||
            request.registryProvenanceOperation != nil ||
            request.registrySBOMArchivePath != nil ||
            request.registrySBOMFormat != nil ||
            request.registrySBOMOutputPath != nil ||
            request.registryProvenanceArchivePath != nil ||
            request.registryProvenanceBuildRecordPath != nil ||
            request.registryProvenanceDescriptorDigest != nil ||
            request.registryProvenanceReferrerDigest != nil ||
            request.registryProvenanceSignerID != nil ||
            request.registryProvenanceSigningKeyReference != nil ||
            request.registrySubjectManifestPath != nil ||
            request.registryCosignPath != nil ||
            request.registryServiceName != nil ||
            request.registryApprovalRecordPath != nil ||
            request.registryExceptionID != nil
        let hasVolumeFields =
            request.volumeOperation != nil ||
            request.volumeIDs != nil ||
            request.volumeResourceID != nil ||
            request.volumeName != nil ||
            request.volumeTargetVolumeID != nil ||
            request.volumeReferenceID != nil ||
            request.volumeOwner != nil ||
            request.volumeOutputPath != nil ||
            request.volumeKeyReference != nil ||
            request.volumeRestoreTargets != nil ||
            request.volumeIdempotencyKey != nil ||
            request.volumeRemoteS3Endpoint != nil ||
            request.volumeRemoteS3Bucket != nil ||
            request.volumeRemoteS3Region != nil ||
            request.volumeRemoteS3Prefix != nil ||
            request.volumeRemoteS3AccessKeyReference != nil ||
            request.volumeRemoteS3SecretKeyReference != nil
        switch request.operation {
        case .events:
            guard !hasLifecycleFields, !hasImageFields,
                  !hasRegistryFields, !hasVolumeFields else {
                throw invalid("Local control events does not accept lifecycle fields.")
            }
        case .recovery:
            guard !hasEventOnlyFilters, !hasLifecycleFields,
                  !hasImageFields, !hasRegistryFields,
                  !hasVolumeFields else {
                throw invalid("Local control recovery accepts only the optional project filter.")
            }
        case .plan, .status, .doctor:
            guard request.project == nil,
                  !hasEventOnlyFilters,
                  !hasLifecycleFields,
                  !hasImageFields,
                  !hasRegistryFields,
                  !hasVolumeFields else {
                throw invalid("This local control operation does not accept filters.")
            }
        case .up, .down, .run, .start, .stop, .restart, .rm, .update:
            guard request.project == nil,
                  !hasEventOnlyFilters,
                  !hasImageFields,
                  !hasRegistryFields,
                  !hasVolumeFields else {
                throw invalid("Local control lifecycle operations accept only lifecycle fields.")
            }
            guard (request.dryRun == true) != (request.confirmPlan != nil) else {
                throw invalid("Local control lifecycle operations require exactly one of dryRun or confirmPlan.")
            }
            if request.operation == .run, request.services?.count != 1 {
                throw invalid("Local control run requires exactly one service.")
            }
        case .image:
            guard request.project == nil,
                  !hasEventOnlyFilters,
                  request.services == nil,
                  request.timeout == nil,
                  request.parallelism == nil,
                  !hasRegistryFields,
                  !hasVolumeFields else {
                throw invalid(
                    "Local control image operations accept only image fields and runtimeProvider."
                )
            }
            try validateImage(request)
        case .registry:
            guard request.project == nil,
                  !hasEventOnlyFilters,
                  request.services == nil,
                  request.dryRun == nil,
                  request.runtimeProvider == nil,
                  request.timeout == nil,
                  request.parallelism == nil,
                  !hasImageFields,
                  !hasVolumeFields else {
                throw invalid(
                    "Local control registry accepts only registry referrer fields and confirmPlan."
                )
            }
            try validateRegistry(request)
        case .volume:
            guard !hasEventOnlyFilters,
                  request.services == nil,
                  request.runtimeProvider == nil,
                  request.parallelism == nil,
                  !hasImageFields,
                  !hasRegistryFields else {
                throw invalid(
                    "Local control volume accepts only volume fields, project for list, timeout, and exact plan confirmation."
                )
            }
            try validateVolume(request)
        }
    }

    private static func validateVolume(
        _ request: LocalControlRequest
    ) throws {
        let operations: Set<String> = [
            "list", "inspect", "capacity", "health", "recover",
            "delete", "prune",
            "snapshot-create", "snapshot-list",
            "snapshot-inspect", "snapshot-retain",
            "snapshot-export", "snapshot-restore",
            "snapshot-delete",
            "backup-create", "backup-list", "backup-inspect",
            "backup-verify", "backup-retain", "backup-restore",
            "backup-delete",
        ]
        guard let operation = request.volumeOperation,
              operations.contains(operation) else {
            throw invalid(
                "Local control volumeOperation is missing or unsupported."
            )
        }
        let ids = request.volumeIDs ?? []
        guard ids.count <= 256,
              Set(ids).count == ids.count,
              ids.allSatisfy(validUUID) else {
            throw invalid(
                "Local control volumeIDs must contain at most 256 unique canonical UUIDs."
            )
        }
        for value in [
            request.volumeResourceID,
            request.volumeTargetVolumeID,
            request.volumeReferenceID,
        ].compactMap({ $0 }) where !validUUID(value) {
            throw invalid(
                "Local control volume resource identities must be canonical UUIDs."
            )
        }
        if let name = request.volumeName,
           name.range(
               of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,127})$",
               options: .regularExpression
           ) == nil {
            throw invalid(
                "Local control volume name must be a bounded safe identifier."
            )
        }
        if let owner = request.volumeOwner,
           owner.range(
               of: "^[A-Za-z0-9](?:[A-Za-z0-9._:/-]{0,255})$",
               options: .regularExpression
           ) == nil {
            throw invalid(
                "Local control volume owner must be a bounded safe identifier."
            )
        }
        if let output = request.volumeOutputPath,
           !validAbsolutePath(output) {
            throw invalid(
                "Local control volume output path must be normalized and absolute."
            )
        }
        if let key = request.volumeKeyReference,
           !validSecretReferenceIdentifier(key) {
            throw invalid(
                "Local control volume key reference must be a typed secret reference."
            )
        }
        if let idempotencyKey = request.volumeIdempotencyKey,
           (!validFilter(idempotencyKey) ||
               idempotencyKey.utf8.count > 256) {
            throw invalid(
                "Local control volume idempotency key must be bounded text without controls."
            )
        }
        let targets = request.volumeRestoreTargets ?? []
        guard targets.count <= 256,
              Set(targets).count == targets.count,
              targets.allSatisfy(validRestoreTarget) else {
            throw invalid(
                "Local control volume restore targets must contain at most 256 unique source=target UUID pairs."
            )
        }
        let targetSources = targets.compactMap {
            $0.split(separator: "=").first.map(String.init)
        }
        let targetDestinations = targets.compactMap {
            $0.split(separator: "=").last.map(String.init)
        }
        guard Set(targetSources).count == targetSources.count,
              Set(targetDestinations).count ==
                targetDestinations.count else {
            throw invalid(
                "Local control volume restore sources and targets must each be unique."
            )
        }
        try validateRemoteBackupDestination(
            request,
            operation: operation
        )

        let destructive: Set<String> = [
            "delete", "prune", "snapshot-restore",
            "snapshot-delete", "backup-restore",
            "backup-delete",
        ]
        if destructive.contains(operation) {
            guard (request.dryRun == true) !=
                    (request.confirmPlan != nil) else {
                throw invalid(
                    "Local control destructive volume operations require exactly one of dryRun or confirmPlan."
                )
            }
        } else {
            guard request.dryRun == nil,
                  request.confirmPlan == nil else {
                throw invalid(
                    "Local control non-destructive volume operations reject plan-confirmation fields."
                )
            }
        }

        let resource = request.volumeResourceID != nil
        let name = request.volumeName != nil
        let target = request.volumeTargetVolumeID != nil
        let reference = request.volumeReferenceID != nil
        let owner = request.volumeOwner != nil
        let output = request.volumeOutputPath != nil
        let key = request.volumeKeyReference != nil
        let restoreTargets = request.volumeRestoreTargets != nil
        let recoveryKey = request.volumeIdempotencyKey != nil
        let project = request.project != nil

        switch operation {
        case "list":
            guard ids.isEmpty, !resource, !name, !target,
                  !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control volume list accepts only an optional project."
                )
            }
        case "inspect":
            guard ids.count == 1, !project, !resource, !name,
                  !target, !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control volume inspect requires exactly one volume ID."
                )
            }
        case "capacity", "health", "prune":
            guard ids.isEmpty, !project, !resource, !name,
                  !target, !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control volume \(operation) accepts no resource fields."
                )
            }
        case "recover":
            guard ids.count == 1, recoveryKey, !project,
                  !resource, !name, !target, !reference,
                  !owner, !output, !key, !restoreTargets else {
                throw invalid(
                    "Local control volume recover requires one volume ID and idempotency key."
                )
            }
        case "delete":
            guard ids.count == 1, !project, !resource, !name,
                  !target, !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control volume delete requires exactly one volume ID."
                )
            }
        case "snapshot-create":
            guard ids.count == 1, resource, name, !project,
                  !target, !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control snapshot create requires one volume ID, resource ID, and name."
                )
            }
        case "snapshot-list":
            guard ids.count == 1, !project, !resource, !name,
                  !target, !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control snapshot list requires one volume ID."
                )
            }
        case "snapshot-inspect", "snapshot-delete":
            guard ids.count == 1, resource, !project, !name,
                  !target, !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control \(operation) requires one volume ID and snapshot ID."
                )
            }
        case "snapshot-retain":
            guard ids.count == 1, resource, owner, !project,
                  !name, !target, !reference, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control snapshot retain requires one volume ID, snapshot ID, and owner."
                )
            }
        case "snapshot-export":
            guard ids.count == 1, resource, output, !project,
                  !name, !target, !reference, !owner, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control snapshot export requires one volume ID, snapshot ID, and output."
                )
            }
        case "snapshot-restore":
            guard ids.count == 1, resource, target, reference,
                  !project, !name, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control snapshot restore requires source volume, snapshot, target volume, and reference IDs."
                )
            }
        case "backup-create":
            guard !ids.isEmpty, resource, name, key, !project,
                  !target, !reference, !owner, !output,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control backup create requires volume IDs, backup ID, name, and key reference."
                )
            }
        case "backup-list":
            guard ids.count == 1, !project, !resource, !name,
                  !target, !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control backup list requires one volume ID."
                )
            }
        case "backup-inspect":
            guard ids.count == 1, resource, !project, !name,
                  !target, !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control backup inspect requires one volume ID and backup ID."
                )
            }
        case "backup-verify":
            guard ids.count == 1, resource, key, !project,
                  !name, !target, !reference, !owner, !output,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control backup verify requires one volume ID, backup ID, and key reference."
                )
            }
        case "backup-retain":
            guard ids.count == 1, resource, owner, !project,
                  !name, !target, !reference, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control backup retain requires one volume ID, backup ID, and owner."
                )
            }
        case "backup-restore":
            guard ids.isEmpty, resource, key, restoreTargets,
                  !targets.isEmpty, !project, !name, !target,
                  !reference, !owner, !output, !recoveryKey else {
                throw invalid(
                    "Local control backup restore requires backup ID, key reference, and restore targets."
                )
            }
        case "backup-delete":
            guard ids.count == 1, resource, !project, !name,
                  !target, !reference, !owner, !output, !key,
                  !restoreTargets, !recoveryKey else {
                throw invalid(
                    "Local control backup delete requires one volume ID and backup ID."
                )
            }
        default:
            throw invalid(
                "Local control volume operation is unsupported."
            )
        }
    }

    private static func validateRemoteBackupDestination(
        _ request: LocalControlRequest,
        operation: String
    ) throws {
        let values = [
            request.volumeRemoteS3Endpoint,
            request.volumeRemoteS3Bucket,
            request.volumeRemoteS3Region,
            request.volumeRemoteS3Prefix,
            request.volumeRemoteS3AccessKeyReference,
            request.volumeRemoteS3SecretKeyReference,
        ]
        guard values.contains(where: { $0 != nil }) else {
            return
        }
        guard [
            "backup-create",
            "backup-verify",
            "backup-retain",
            "backup-restore",
            "backup-delete",
        ].contains(operation) else {
            throw invalid(
                "Local control remote S3 fields are supported only for backup create, verify, retain, restore, and delete."
            )
        }
        guard let endpoint = request.volumeRemoteS3Endpoint,
              let bucket = request.volumeRemoteS3Bucket,
              let region = request.volumeRemoteS3Region,
              let accessKey = request
                .volumeRemoteS3AccessKeyReference,
              let secretKey = request
                .volumeRemoteS3SecretKeyReference else {
            throw invalid(
                "Local control remote S3 requires endpoint, bucket, region, access-key reference, and secret-key reference."
            )
        }
        let endpointURL = URL(string: endpoint)
        guard endpointURL?.scheme == "https",
              endpointURL?.host?.isEmpty == false,
              endpointURL?.user == nil,
              endpointURL?.password == nil,
              endpointURL?.query == nil,
              endpointURL?.fragment == nil,
              endpointURL?.path.isEmpty == true ||
                endpointURL?.path == "/",
              (3...63).contains(bucket.utf8.count),
              bucket.first.map({
                  $0.isLetter || $0.isNumber
              }) == true,
              bucket.last.map({
                  $0.isLetter || $0.isNumber
              }) == true,
              bucket.allSatisfy({
                  $0.isLowercase || $0.isNumber ||
                    $0 == "." || $0 == "-"
              }),
              !bucket.contains(".."),
              (1...64).contains(region.utf8.count),
              region.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "-"
              }) else {
            throw invalid(
                "Local control remote S3 endpoint, bucket, or region is invalid."
            )
        }
        let prefix = request.volumeRemoteS3Prefix ?? ""
        guard prefix.utf8.count <= 512,
              !prefix.hasPrefix("/"),
              !prefix.hasSuffix("/"),
              prefix.isEmpty || prefix.split(
                  separator: "/",
                  omittingEmptySubsequences: false
              ).allSatisfy({
                  !$0.isEmpty &&
                    $0 != "." &&
                    $0 != ".." &&
                    $0.allSatisfy {
                        $0.isLetter || $0.isNumber ||
                            $0 == "." || $0 == "_" ||
                            $0 == "-"
                    }
              }) else {
            throw invalid(
                "Local control remote S3 prefix is invalid."
            )
        }
        guard validKeychainReference(accessKey),
              validKeychainReference(secretKey),
              accessKey != secretKey else {
            throw invalid(
                "Local control remote S3 credentials require two distinct typed Keychain references."
            )
        }
    }

    private static func validKeychainReference(
        _ value: String
    ) -> Bool {
        value.range(
            of: #"^keychain://[A-Za-z0-9._:@-]{1,128}/[A-Za-z0-9._:@-]{1,128}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validRestoreTarget(_ value: String) -> Bool {
        let parts = value.split(
            separator: "=",
            omittingEmptySubsequences: false
        )
        return parts.count == 2 &&
            validUUID(String(parts[0])) &&
            validUUID(String(parts[1]))
    }

    private static func validateRegistry(
        _ request: LocalControlRequest
    ) throws {
        let hasReferrerOperation =
            request.registryReferrerOperation != nil
        let hasTrustOperation = request.registryTrustOperation != nil
        let hasSBOMOperation = request.registrySBOMOperation != nil
        let hasVulnerabilityOperation =
            request.registryVulnerabilityOperation != nil
        let hasProvenanceOperation =
            request.registryProvenanceOperation != nil
        guard [
            hasReferrerOperation,
            hasTrustOperation,
            hasSBOMOperation,
            hasVulnerabilityOperation,
            hasProvenanceOperation
        ].filter({ $0 }).count == 1 else {
            throw invalid(
                "Local control registry requires exactly one referrer, trust, SBOM, vulnerability, or provenance operation."
            )
        }
        if hasProvenanceOperation {
            try validateRegistryProvenance(request)
        } else if hasTrustOperation {
            try validateRegistryTrust(request)
        } else if hasSBOMOperation {
            try validateRegistrySBOM(request)
        } else if hasVulnerabilityOperation {
            try validateRegistryVulnerability(request)
        } else {
            guard request.registrySubjectManifestPath == nil,
                  request.registryCosignPath == nil,
                  request.registryServiceName == nil,
                  request.registryApprovalRecordPath == nil,
                  request.registryExceptionID == nil,
                  request.registrySBOMArchivePath == nil,
                  request.registrySBOMFormat == nil,
                  request.registrySBOMOutputPath == nil,
                  request.registryProvenanceArchivePath == nil,
                  request.registryProvenanceBuildRecordPath == nil,
                  request.registryProvenanceDescriptorDigest == nil,
                  request.registryProvenanceReferrerDigest == nil,
                  request.registryProvenanceSignerID == nil,
                  request.registryProvenanceSigningKeyReference == nil else {
                throw invalid(
                    "Local control registry referrer operations reject trust, SBOM, vulnerability, and provenance fields."
                )
            }
            try validateRegistryReferrers(request)
        }
    }

    private static func validateRegistryProvenance(
        _ request: LocalControlRequest
    ) throws {
        guard let operation = request.registryProvenanceOperation,
              ["generate", "verify", "status", "resume"]
                .contains(operation),
              request.registryReferrerOperation == nil,
              request.registryTrustOperation == nil,
              request.registrySBOMOperation == nil,
              request.registryVulnerabilityOperation == nil,
              request.registrySubjectDigest == nil,
              request.registryArtifactType == nil,
              request.registryTargetServer == nil,
              request.registryTargetRepository == nil,
              request.registryLeaseID == nil,
              request.registryFencingToken == nil,
              request.registryOwnerID == nil,
              request.registryExpiresAt == nil,
              request.registryOffline == nil,
              request.registrySBOMArchivePath == nil,
              request.registrySBOMFormat == nil,
              request.registrySBOMOutputPath == nil,
              request.registryProvenanceDescriptorDigest == nil,
              request.registryProvenanceReferrerDigest == nil,
              request.registrySubjectManifestPath == nil,
              request.registryCosignPath == nil,
              request.registryApprovalRecordPath == nil,
              request.registryExceptionID == nil else {
            throw invalid(
                "Local control registry provenance fields are incompatible."
            )
        }
        for path in [
            request.registryProvenanceArchivePath,
            request.registryProvenanceBuildRecordPath
        ].compactMap({ $0 }) where !validAbsolutePath(path) {
            throw invalid(
                "Local control registry provenance paths must be normalized absolute paths."
            )
        }
        if let service = request.registryServiceName,
           !validServiceName(service) {
            throw invalid(
                "Local control registry provenance service is invalid."
            )
        }
        if let server = request.registryServer,
           (try? RegistryEndpoint(server)) == nil {
            throw invalid(
                "Local control registry provenance server must be an exact HTTPS host or host:port."
            )
        }
        if let repository = request.registryRepository,
           (try? OCIRepositoryName(repository)) == nil {
            throw invalid(
                "Local control registry provenance repository is invalid."
            )
        }
        if let discovery = request.registryDiscoveryID,
           !validUUID(discovery) {
            throw invalid(
                "Local control registry provenance discovery must be an exact UUID."
            )
        }
        if let digest = request.registryReferrerDigest,
           (try? OCIContentDigest(digest)) == nil {
            throw invalid(
                "Local control registry provenance referrer digest must be canonical."
            )
        }
        if let group = request.registryOperationGroupID,
           !validUUID(group) {
            throw invalid(
                "Local control registry provenance operation group must be an exact UUID."
            )
        }
        if let confirmation = request.confirmPlan,
           !validSHA256(confirmation) {
            throw invalid(
                "Local control registry provenance confirmPlan must be an exact lowercase SHA-256."
            )
        }
        if let signer = request.registryProvenanceSignerID,
           signer.range(
               of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,127})$",
               options: .regularExpression
           ) == nil {
            throw invalid(
                "Local control registry provenance signer must be a bounded safe identifier."
            )
        }
        if let reference =
            request.registryProvenanceSigningKeyReference,
           !validSecretReferenceIdentifier(reference) {
            throw invalid(
                "Local control registry provenance signing key must be a typed secret reference."
            )
        }

        let archive = request.registryProvenanceArchivePath != nil
        let buildRecord =
            request.registryProvenanceBuildRecordPath != nil
        let server = request.registryServer != nil
        let repository = request.registryRepository != nil
        let discovery = request.registryDiscoveryID != nil
        let digest = request.registryReferrerDigest != nil
        let signer = request.registryProvenanceSignerID != nil
        let signingKey =
            request.registryProvenanceSigningKeyReference != nil
        let group = request.registryOperationGroupID != nil
        let confirmation = request.confirmPlan != nil
        switch operation {
        case "generate":
            guard archive, buildRecord, server, repository,
                  signer, signingKey, !discovery, !digest,
                  !group, !confirmation else {
                throw invalid(
                    "Local control registry provenance generate fields are incomplete or incompatible."
                )
            }
        case "verify":
            guard discovery, digest, !archive, !buildRecord,
                  !server, !repository, !signer, !signingKey,
                  !group, !confirmation else {
                throw invalid(
                    "Local control registry provenance verify requires only discovery, exact referrer digest, and optional service."
                )
            }
        case "status":
            guard !archive, !buildRecord, !server, !repository,
                  !discovery, !digest, !signer, !signingKey,
                  !group, !confirmation else {
                throw invalid(
                    "Local control registry provenance status accepts only an optional service."
                )
            }
        case "resume":
            guard group, confirmation, !archive, !buildRecord,
                  !server, !repository, !discovery, !digest,
                  !signer, request.registryServiceName == nil else {
                throw invalid(
                    "Local control registry provenance resume requires operationGroupID, confirmPlan, and an optional typed signing key reference."
                )
            }
        default:
            throw invalid(
                "Local control registry provenance operation is unsupported."
            )
        }
    }

    private static func validateRegistryVulnerability(
        _ request: LocalControlRequest
    ) throws {
        guard let operation =
                request.registryVulnerabilityOperation,
              [
                "evaluate", "status", "grant-exception",
                "revoke-exception", "resume"
              ].contains(operation),
              request.registryReferrerOperation == nil,
              request.registryTrustOperation == nil,
              request.registrySBOMOperation == nil,
              request.registryProvenanceOperation == nil,
              request.registryServer == nil,
              request.registryRepository == nil,
              request.registrySubjectDigest == nil,
              request.registryArtifactType == nil,
              request.registryTargetServer == nil,
              request.registryTargetRepository == nil,
              request.registryLeaseID == nil,
              request.registryFencingToken == nil,
              request.registryOwnerID == nil,
              request.registryExpiresAt == nil,
              request.registryOffline == nil,
              request.registrySBOMArchivePath == nil,
              request.registrySBOMFormat == nil,
              request.registrySBOMOutputPath == nil,
              request.registryProvenanceArchivePath == nil,
              request.registryProvenanceBuildRecordPath == nil,
              request.registryProvenanceDescriptorDigest == nil,
              request.registryProvenanceReferrerDigest == nil,
              request.registryProvenanceSignerID == nil,
              request.registryProvenanceSigningKeyReference == nil,
              request.registrySubjectManifestPath == nil else {
            throw invalid(
                "Local control registry vulnerability fields are incompatible."
            )
        }
        if let discovery = request.registryDiscoveryID,
           !validUUID(discovery) {
            throw invalid(
                "Local control registry vulnerability discovery must be an exact UUID."
            )
        }
        if let digest = request.registryReferrerDigest,
           (try? OCIContentDigest(digest)) == nil {
            throw invalid(
                "Local control registry vulnerability report digest must be canonical."
            )
        }
        if let group = request.registryOperationGroupID,
           !validUUID(group) {
            throw invalid(
                "Local control registry vulnerability operation group must be an exact UUID."
            )
        }
        if let exceptionID = request.registryExceptionID,
           !validUUID(exceptionID) {
            throw invalid(
                "Local control registry vulnerability exception must be an exact UUID."
            )
        }
        if let service = request.registryServiceName,
           !validServiceName(service) {
            throw invalid(
                "Local control registry vulnerability service is invalid."
            )
        }
        for path in [
            request.registryCosignPath,
            request.registryApprovalRecordPath
        ].compactMap({ $0 }) where !validAbsolutePath(path) {
            throw invalid(
                "Local control registry vulnerability paths must be normalized absolute paths."
            )
        }
        if let confirmation = request.confirmPlan,
           !validSHA256(confirmation) {
            throw invalid(
                "Local control registry vulnerability confirmPlan must be an exact lowercase SHA-256."
            )
        }

        let discovery = request.registryDiscoveryID != nil
        let digest = request.registryReferrerDigest != nil
        let cosign = request.registryCosignPath != nil
        let approval = request.registryApprovalRecordPath != nil
        let exception = request.registryExceptionID != nil
        let group = request.registryOperationGroupID != nil
        let confirmation = request.confirmPlan != nil
        switch operation {
        case "evaluate":
            guard discovery, digest, cosign,
                  !approval, !exception, !group, !confirmation else {
                throw invalid(
                    "Local control registry vulnerability evaluate requires discovery, exact report digest, cosign path, and optional service."
                )
            }
        case "status":
            guard !discovery, !digest, !cosign, !approval,
                  !exception, !group, !confirmation else {
                throw invalid(
                    "Local control registry vulnerability status accepts only an optional service."
                )
            }
        case "grant-exception":
            guard approval, !discovery, !digest, !cosign,
                  !exception, !group, !confirmation,
                  request.registryServiceName == nil else {
                throw invalid(
                    "Local control registry vulnerability grant-exception requires only an approval record."
                )
            }
        case "revoke-exception":
            guard exception, !discovery, !digest, !cosign,
                  !approval, !group, !confirmation,
                  request.registryServiceName == nil else {
                throw invalid(
                    "Local control registry vulnerability revoke-exception requires only an exception ID."
                )
            }
        case "resume":
            guard group, confirmation, !discovery, !digest,
                  !cosign, !approval, !exception,
                  request.registryServiceName == nil else {
                throw invalid(
                    "Local control registry vulnerability resume requires only operationGroupID and confirmPlan."
                )
            }
        default:
            throw invalid(
                "Local control registry vulnerability operation is unsupported."
            )
        }
    }

    private static func validateRegistrySBOM(
        _ request: LocalControlRequest
    ) throws {
        guard let operation = request.registrySBOMOperation,
              ["generate", "ingest", "query", "export", "resume"]
                .contains(operation),
              request.registryReferrerOperation == nil,
              request.registryTrustOperation == nil,
              request.registryVulnerabilityOperation == nil,
              request.registryProvenanceOperation == nil,
              request.registrySubjectDigest == nil,
              request.registryArtifactType == nil,
              request.registryTargetServer == nil,
              request.registryTargetRepository == nil,
              request.registryReferrerDigest == nil,
              request.registryLeaseID == nil,
              request.registryFencingToken == nil,
              request.registryOwnerID == nil,
              request.registryExpiresAt == nil,
              request.registryOffline == nil,
              request.registrySubjectManifestPath == nil,
              request.registryCosignPath == nil,
              request.registryApprovalRecordPath == nil,
              request.registryExceptionID == nil,
              request.registryProvenanceArchivePath == nil,
              request.registryProvenanceBuildRecordPath == nil,
              request.registryProvenanceSignerID == nil,
              request.registryProvenanceSigningKeyReference == nil else {
            throw invalid(
                "Local control registry SBOM fields are incompatible."
            )
        }
        for path in [
            request.registrySBOMArchivePath,
            request.registrySBOMOutputPath
        ].compactMap({ $0 }) where !validAbsolutePath(path) {
            throw invalid(
                "Local control registry SBOM paths must be normalized absolute paths."
            )
        }
        if let service = request.registryServiceName,
           !validServiceName(service) {
            throw invalid(
                "Local control registry SBOM service is invalid."
            )
        }
        if let server = request.registryServer,
           (try? RegistryEndpoint(server)) == nil {
            throw invalid(
                "Local control registry SBOM server must be an exact HTTPS host or host:port."
            )
        }
        if let repository = request.registryRepository,
           (try? OCIRepositoryName(repository)) == nil {
            throw invalid(
                "Local control registry SBOM repository is invalid."
            )
        }
        if let discovery = request.registryDiscoveryID,
           !validUUID(discovery) {
            throw invalid(
                "Local control registry SBOM discovery must be an exact UUID."
            )
        }
        if let group = request.registryOperationGroupID,
           !validUUID(group) {
            throw invalid(
                "Local control registry SBOM operation group must be an exact UUID."
            )
        }
        if let confirmation = request.confirmPlan,
           !validSHA256(confirmation) {
            throw invalid(
                "Local control registry SBOM confirmPlan must be an exact lowercase SHA-256."
            )
        }
        if let format = request.registrySBOMFormat,
           ImageSBOMFormat(rawValue: format) == nil {
            throw invalid(
                "Local control registry SBOM format is unsupported."
            )
        }
        for digest in [
            request.registryProvenanceDescriptorDigest,
            request.registryProvenanceReferrerDigest
        ].compactMap({ $0 }) where
            (try? OCIContentDigest(digest)) == nil {
            throw invalid(
                "Local control registry SBOM provenance digests must be canonical."
            )
        }

        let archive = request.registrySBOMArchivePath != nil
        let server = request.registryServer != nil
        let repository = request.registryRepository != nil
        let discovery = request.registryDiscoveryID != nil
        let format = request.registrySBOMFormat != nil
        let outputPath = request.registrySBOMOutputPath != nil
        let provenanceDescriptor =
            request.registryProvenanceDescriptorDigest != nil
        let provenanceReferrer =
            request.registryProvenanceReferrerDigest != nil
        let group = request.registryOperationGroupID != nil
        let confirmation = request.confirmPlan != nil
        guard provenanceDescriptor == provenanceReferrer else {
            throw invalid(
                "Local control registry SBOM provenance requires both exact digests."
            )
        }
        switch operation {
        case "generate":
            guard archive, server, repository, format,
                  !discovery, !outputPath, !group, !confirmation else {
                throw invalid(
                    "Local control registry SBOM generate fields are incomplete or incompatible."
                )
            }
        case "ingest":
            guard discovery, !archive, !server, !repository,
                  !format, !outputPath, !provenanceDescriptor,
                  !group, !confirmation else {
                throw invalid(
                    "Local control registry SBOM ingest requires only a discovery and optional service."
                )
            }
        case "query":
            guard !archive, !server, !repository, !discovery,
                  !format, !outputPath, !provenanceDescriptor,
                  !group, !confirmation else {
                throw invalid(
                    "Local control registry SBOM query accepts only an optional service."
                )
            }
        case "export":
            guard format, outputPath, !archive, !server,
                  !repository, !discovery, !provenanceDescriptor,
                  !group, !confirmation else {
                throw invalid(
                    "Local control registry SBOM export requires only format, output path, and optional service."
                )
            }
        case "resume":
            guard group, confirmation, !archive, !server,
                  !repository, !discovery, !format, !outputPath,
                  !provenanceDescriptor,
                  request.registryServiceName == nil else {
                throw invalid(
                    "Local control registry SBOM resume requires only operationGroupID and confirmPlan."
                )
            }
        default:
            throw invalid(
                "Local control registry SBOM operation is unsupported."
            )
        }
    }

    private static func validateRegistryTrust(
        _ request: LocalControlRequest
    ) throws {
        guard let operation = request.registryTrustOperation,
              ["verify", "status", "grant-exception", "revoke-exception"]
                .contains(operation),
              request.registryReferrerOperation == nil,
              request.registryServer == nil,
              request.registryRepository == nil,
              request.registrySubjectDigest == nil,
              request.registryArtifactType == nil,
              request.registryTargetServer == nil,
              request.registryTargetRepository == nil,
              request.registryReferrerDigest == nil,
              request.registryLeaseID == nil,
              request.registryFencingToken == nil,
              request.registryOwnerID == nil,
              request.registryExpiresAt == nil,
              request.registryOperationGroupID == nil,
              request.registryOffline == nil,
              request.registrySBOMOperation == nil,
              request.registryVulnerabilityOperation == nil,
              request.registryProvenanceOperation == nil,
              request.registrySBOMArchivePath == nil,
              request.registrySBOMFormat == nil,
              request.registrySBOMOutputPath == nil,
              request.registryProvenanceArchivePath == nil,
              request.registryProvenanceBuildRecordPath == nil,
              request.registryProvenanceDescriptorDigest == nil,
              request.registryProvenanceReferrerDigest == nil,
              request.registryProvenanceSignerID == nil,
              request.registryProvenanceSigningKeyReference == nil,
              request.confirmPlan == nil else {
            throw invalid(
                "Local control registry trust fields are incompatible."
            )
        }
        for path in [
            request.registrySubjectManifestPath,
            request.registryCosignPath,
            request.registryApprovalRecordPath
        ].compactMap({ $0 }) {
            guard validAbsolutePath(path) else {
                throw invalid(
                    "Local control registry trust paths must be normalized absolute paths."
                )
            }
        }
        if let service = request.registryServiceName,
           !validServiceName(service) {
            throw invalid(
                "Local control registry trust service is invalid."
            )
        }
        for identifier in [
            request.registryDiscoveryID,
            request.registryExceptionID
        ].compactMap({ $0 }) where !validUUID(identifier) {
            throw invalid(
                "Local control registry trust identifiers must be exact UUIDs."
            )
        }
        let discovery = request.registryDiscoveryID != nil
        let subject = request.registrySubjectManifestPath != nil
        let cosign = request.registryCosignPath != nil
        let service = request.registryServiceName != nil
        let approval = request.registryApprovalRecordPath != nil
        let exception = request.registryExceptionID != nil
        switch operation {
        case "verify":
            guard discovery, subject, cosign, !approval, !exception else {
                throw invalid(
                    "Local control registry trust verify requires discoveryID, subject manifest, and cosign."
                )
            }
        case "status":
            guard !discovery, !subject, !cosign, !approval, !exception else {
                throw invalid(
                    "Local control registry trust status accepts only an optional service."
                )
            }
        case "grant-exception":
            guard approval, !discovery, !subject, !cosign,
                  !service, !exception else {
                throw invalid(
                    "Local control registry trust grant-exception requires only an approval record."
                )
            }
        case "revoke-exception":
            guard exception, !discovery, !subject, !cosign,
                  !service, !approval else {
                throw invalid(
                    "Local control registry trust revoke-exception requires only an exception ID."
                )
            }
        default:
            throw invalid(
                "Local control registry trust operation is unsupported."
            )
        }
    }

    private static func validateRegistryReferrers(
        _ request: LocalControlRequest
    ) throws {
        guard let operation = request.registryReferrerOperation,
              [
                  "discover", "fetch", "publish", "copy", "retain",
                  "release", "status", "prune", "resume"
              ].contains(operation) else {
            throw invalid(
                "Local control registryReferrerOperation is unsupported."
            )
        }
        for value in [
            request.registryServer,
            request.registryRepository,
            request.registrySubjectDigest,
            request.registryArtifactType,
            request.registryTargetServer,
            request.registryTargetRepository,
            request.registryReferrerDigest,
            request.registryOwnerID,
            request.registryExpiresAt
        ].compactMap({ $0 }) {
            guard !value.isEmpty,
                  value.utf8.count <= 512,
                  !value.hasPrefix("-"),
                  !value.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw invalid(
                    "Local control registry referrer strings must be bounded safe values."
                )
            }
        }
        for value in [
            request.registryDiscoveryID,
            request.registryLeaseID,
            request.registryFencingToken,
            request.registryOperationGroupID
        ].compactMap({ $0 }) where !validUUID(value) {
            throw invalid(
                "Local control registry identifiers must be exact UUIDs."
            )
        }
        if let confirmation = request.confirmPlan,
           !validSHA256(confirmation) {
            throw invalid(
                "Local control registry confirmPlan must be an exact lowercase SHA-256."
            )
        }
        for server in [
            request.registryServer,
            request.registryTargetServer
        ].compactMap({ $0 }) where
            (try? RegistryEndpoint(server)) == nil {
            throw invalid(
                "Local control registry server must be an exact HTTPS host or host:port."
            )
        }
        for repository in [
            request.registryRepository,
            request.registryTargetRepository
        ].compactMap({ $0 }) where
            (try? OCIRepositoryName(repository)) == nil {
            throw invalid(
                "Local control registry repository is invalid."
            )
        }
        for digest in [
            request.registrySubjectDigest,
            request.registryReferrerDigest
        ].compactMap({ $0 }) where
            (try? OCIContentDigest(digest)) == nil {
            throw invalid(
                "Local control registry digest must be canonical."
            )
        }
        if let artifact = request.registryArtifactType,
           (try? OCIArtifactType(artifact)) == nil {
            throw invalid(
                "Local control registry artifact type is invalid."
            )
        }
        if let owner = request.registryOwnerID,
           owner.range(
               of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,127})$",
               options: .regularExpression
           ) == nil {
            throw invalid(
                "Local control registry owner is invalid."
            )
        }
        if let expiry = request.registryExpiresAt,
           !validTimestamp(expiry) {
            throw invalid(
                "Local control registry lease expiry is invalid."
            )
        }
        if let offline = request.registryOffline, !offline {
            throw invalid(
                "Local control registryOffline, when present, must be true."
            )
        }

        let server = request.registryServer != nil
        let repository = request.registryRepository != nil
        let subject = request.registrySubjectDigest != nil
        let artifact = request.registryArtifactType != nil
        let targetServer = request.registryTargetServer != nil
        let targetRepository =
            request.registryTargetRepository != nil
        let discovery = request.registryDiscoveryID != nil
        let digest = request.registryReferrerDigest != nil
        let lease = request.registryLeaseID != nil
        let fence = request.registryFencingToken != nil
        let owner = request.registryOwnerID != nil
        let expires = request.registryExpiresAt != nil
        let group = request.registryOperationGroupID != nil
        let offline = request.registryOffline != nil
        let confirmation = request.confirmPlan != nil

        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw invalid(message) }
        }
        switch operation {
        case "discover", "fetch":
            try require(
                server && repository && subject &&
                    !targetServer && !targetRepository &&
                    !discovery && !digest && !lease && !fence &&
                    !owner && !expires && !group && !confirmation,
                "Local control registry discover/fetch fields are incomplete or incompatible."
            )
        case "publish":
            try require(
                discovery && targetServer && targetRepository &&
                    !server && !repository && !subject && !artifact &&
                    !digest && !lease && !fence && !owner &&
                    !expires && !group && !offline && !confirmation,
                "Local control registry publish fields are incomplete or incompatible."
            )
        case "copy":
            try require(
                server && repository && subject &&
                    targetServer && targetRepository &&
                    !discovery && !digest && !lease && !fence &&
                    !owner && !expires && !group && !offline &&
                    !confirmation,
                "Local control registry copy fields are incomplete or incompatible."
            )
        case "retain":
            try require(
                discovery && owner && expires &&
                    !server && !repository && !subject && !artifact &&
                    !targetServer && !targetRepository && !digest &&
                    !lease && !fence && !group && !offline &&
                    !confirmation,
                "Local control registry retain fields are incomplete or incompatible."
            )
        case "release":
            try require(
                lease && fence &&
                    !server && !repository && !subject && !artifact &&
                    !targetServer && !targetRepository && !discovery &&
                    !digest && !owner && !expires && !group &&
                    !offline && !confirmation,
                "Local control registry release fields are incomplete or incompatible."
            )
        case "status":
            try require(
                discovery &&
                    !server && !repository && !subject && !artifact &&
                    !targetServer && !targetRepository && !digest &&
                    !lease && !fence && !owner && !expires && !group &&
                    !offline && !confirmation,
                "Local control registry status requires only registryDiscoveryID."
            )
        case "prune":
            try require(
                discovery && digest &&
                    !server && !repository && !subject && !artifact &&
                    !targetServer && !targetRepository && !lease &&
                    !fence && !owner && !expires && !group && !offline,
                "Local control registry prune fields are incomplete or incompatible."
            )
        case "resume":
            try require(
                group && confirmation &&
                    !server && !repository && !subject && !artifact &&
                    !targetServer && !targetRepository && !discovery &&
                    !digest && !lease && !fence && !owner &&
                    !expires && !offline,
                "Local control registry resume requires operationGroupID and confirmPlan."
            )
        default:
            throw invalid(
                "Unsupported local control registry operation."
            )
        }
    }

    private static func validateImage(_ request: LocalControlRequest) throws {
        let operations = [
            "inspect", "pull", "build", "push", "tag", "load", "save",
            "delete", "prune", "cache-status", "pin", "unpin"
        ]
        guard let operation = request.imageOperation,
              operations.contains(operation) else {
            throw invalid(
                "Local control imageOperation must be one supported image lifecycle operation."
            )
        }
        let references = request.imageReferences ?? []
        guard references.count <= 256,
              Set(references).count == references.count,
              references.allSatisfy(validImageReference) else {
            throw invalid(
                "Local control imageReferences must contain unique bounded OCI references."
            )
        }
        if let target = request.imageTargetReference,
           !validImageReference(target) {
            throw invalid("Local control imageTargetReference is invalid.")
        }
        for path in [
            request.imageContextPath,
            request.imageFilePath,
            request.imageArchivePath
        ].compactMap({ $0 }) where !validAbsolutePath(path) {
            throw invalid(
                "Local control image paths must be normalized absolute paths."
            )
        }
        if let context = request.imageContextPath,
           let file = request.imageFilePath {
            let prefix = context == "/" ? "/" : context + "/"
            guard file.hasPrefix(prefix) else {
                throw invalid(
                    "Local control imageFilePath must be beneath imageContextPath."
                )
            }
        }
        if let platform = request.imagePlatform,
           !["linux/arm64", "linux/amd64"].contains(platform) {
            throw invalid(
                "Local control imagePlatform supports linux/arm64 or linux/amd64."
            )
        }
        if let progress = request.imageProgress,
           !["none", "plain"].contains(progress) {
            throw invalid(
                "Local control imageProgress supports none or plain."
            )
        }
        if let maximumBytes = request.imageMaximumBytes,
           maximumBytes <= 0 {
            throw invalid(
                "Local control imageMaximumBytes must be positive."
            )
        }
        if let targetBytes = request.imageTargetBytes,
           targetBytes < 0 {
            throw invalid(
                "Local control imageTargetBytes must be nonnegative."
            )
        }
        if operation == "prune" {
            guard (request.imageMaximumBytes == nil) ==
                    (request.imageTargetBytes == nil) else {
                throw invalid(
                    "Local control imageMaximumBytes and imageTargetBytes must be supplied together."
                )
            }
        }
        if let maximumBytes = request.imageMaximumBytes,
           let targetBytes = request.imageTargetBytes,
           targetBytes > maximumBytes {
            throw invalid(
                "Local control imageTargetBytes must not exceed imageMaximumBytes."
            )
        }
        if let retentionSeconds = request.imageRetentionSeconds,
           !(0...31_536_000).contains(retentionSeconds) {
            throw invalid(
                "Local control imageRetentionSeconds must be between 0 and 31536000."
            )
        }
        if let maximumDeletions = request.imageMaximumDeletions,
           !(1...256).contains(maximumDeletions) {
            throw invalid(
                "Local control imageMaximumDeletions must be between 1 and 256."
            )
        }

        let hasTarget = request.imageTargetReference != nil
        let hasReferences = request.imageReferences != nil
        let hasContext = request.imageContextPath != nil
        let hasFile = request.imageFilePath != nil
        let hasArchive = request.imageArchivePath != nil
        let hasPlatform = request.imagePlatform != nil
        let hasOffline = request.imageOffline != nil
        let hasNoCache = request.imageNoCache != nil
        let hasProgress = request.imageProgress != nil
        let hasMaximumBytes = request.imageMaximumBytes != nil
        let hasTargetBytes = request.imageTargetBytes != nil
        let hasRetention = request.imageRetentionSeconds != nil
        let hasMaximumDeletions =
            request.imageMaximumDeletions != nil
        let hasPrunePolicy = hasMaximumBytes || hasTargetBytes ||
            hasRetention || hasMaximumDeletions
        let hasPlanControl = request.dryRun != nil ||
            request.confirmPlan != nil

        func exactReferences(_ count: Int) -> Bool {
            references.count == count
        }
        func require(
            _ condition: Bool,
            _ message: String
        ) throws {
            guard condition else { throw invalid(message) }
        }
        switch operation {
        case "inspect":
            try require(
                hasReferences && !references.isEmpty &&
                    !hasTarget && !hasContext &&
                    !hasFile && !hasArchive && !hasPlatform &&
                    !hasOffline && !hasNoCache && !hasProgress &&
                    !hasPrunePolicy && !hasPlanControl,
                "Local control image inspect requires only imageReferences."
            )
        case "pull":
            try require(
                hasReferences && exactReferences(1) &&
                    !hasTarget && !hasContext &&
                    !hasFile && !hasArchive && !hasNoCache &&
                    !hasPrunePolicy && !hasPlanControl,
                "Local control image pull requires one reference and optional platform, offline, and progress."
            )
        case "push":
            try require(
                hasReferences && exactReferences(1) &&
                    !hasTarget && !hasContext &&
                    !hasFile && !hasArchive && !hasNoCache &&
                    !hasPrunePolicy && !hasPlanControl,
                "Local control image push requires one reference and optional platform, offline, and progress."
            )
        case "tag":
            try require(
                hasReferences && exactReferences(1) &&
                    hasTarget && !hasContext &&
                    !hasFile && !hasArchive && !hasPlatform &&
                    !hasOffline && !hasNoCache && !hasProgress &&
                    !hasPrunePolicy && !hasPlanControl,
                "Local control image tag requires one source and one target."
            )
        case "load":
            try require(
                hasReferences && !references.isEmpty &&
                    hasArchive && !hasTarget &&
                    !hasContext && !hasFile && !hasPlatform &&
                    !hasOffline && !hasNoCache && !hasProgress &&
                    !hasPrunePolicy && !hasPlanControl,
                "Local control image load requires expected references and one archive path."
            )
        case "save":
            try require(
                hasReferences && !references.isEmpty &&
                    hasArchive && !hasTarget &&
                    !hasContext && !hasFile && !hasOffline &&
                    !hasNoCache && !hasProgress &&
                    !hasPrunePolicy && !hasPlanControl,
                "Local control image save requires references and one archive path."
            )
        case "build":
            try require(
                !hasReferences && hasTarget && hasContext &&
                    !hasArchive && !hasProgress &&
                    !hasPrunePolicy && !hasPlanControl,
                "Local control image build requires target and context paths."
            )
        case "delete":
            try require(
                hasReferences && !references.isEmpty &&
                    !hasTarget && !hasContext &&
                    !hasFile && !hasArchive && !hasPlatform &&
                    !hasOffline && !hasNoCache && !hasProgress &&
                    !hasPrunePolicy && !hasPlanControl,
                "Local control image delete requires only imageReferences."
            )
        case "prune":
            try require(
                !hasReferences && !hasTarget && !hasContext &&
                    !hasFile && !hasArchive && !hasPlatform &&
                    !hasOffline && !hasNoCache && !hasProgress &&
                    !(request.dryRun == true &&
                        request.confirmPlan != nil),
                "Local control image prune accepts only bounded policy fields and at most one plan control."
            )
        case "cache-status":
            try require(
                !hasReferences && !hasTarget && !hasContext &&
                    !hasFile && !hasArchive && !hasPlatform &&
                    !hasOffline && !hasNoCache && !hasProgress &&
                    !hasTargetBytes && !hasRetention &&
                    !hasMaximumDeletions && !hasPlanControl,
                "Local control image cache-status accepts only optional imageMaximumBytes."
            )
        case "pin", "unpin":
            try require(
                hasReferences && exactReferences(1) &&
                    !hasTarget && !hasContext &&
                    !hasFile && !hasArchive && !hasPlatform &&
                    !hasOffline && !hasNoCache && !hasProgress &&
                    !hasPrunePolicy && !hasPlanControl,
                "Local control image pin and unpin require one managed reference."
            )
        default:
            throw invalid("Unsupported local control image operation.")
        }
    }

    private static func validImageReference(_ value: String) -> Bool {
        (try? RuntimeImageLifecycleContract.validatedReference(value)) != nil
    }

    private static func validAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") &&
            value.utf8.count <= 4_096 &&
            !value.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).contains("..") &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            } &&
            URL(fileURLWithPath: value).standardizedFileURL.path == value
    }

    private static func validSecretReferenceIdentifier(
        _ value: String
    ) -> Bool {
        guard value == value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
        !value.isEmpty,
        value.utf8.count <= 4_096,
        !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            return false
        }
        if value.range(
            of: #"^keychain://[A-Za-z0-9._:@-]{1,128}/[A-Za-z0-9._:@-]{1,128}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if value.range(
            of: #"^(?:external|plugin)://[A-Za-z0-9][A-Za-z0-9._-]{0,127}/[A-Za-z0-9._:@-]{1,128}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if value.hasPrefix("env-file://") {
            let remainder = String(
                value.dropFirst("env-file://".count)
            )
            guard let separator = remainder.lastIndex(of: "#")
            else {
                return false
            }
            let path = String(remainder[..<separator])
            let key = String(
                remainder[remainder.index(after: separator)...]
            )
            return !path.contains("#") &&
                validAbsolutePath(path) &&
                key.range(
                    of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$",
                    options: .regularExpression
                ) != nil
        }
        if value.hasPrefix("local-file://") {
            let path = String(
                value.dropFirst("local-file://".count)
            )
            return !path.contains("#") && validAbsolutePath(path)
        }
        return false
    }

    private static func validFilter(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty &&
            trimmed.count <= 128 &&
            !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validServiceName(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$",
            options: .regularExpression
        ) != nil
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func validUUID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    private static func validTimestamp(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) != nil ||
            whole.date(from: value) != nil
    }

    private static func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .controlAPIInvalid, message: message)
    }
}

private enum StrictControlJSONObject {
    static func validate(
        _ data: Data,
        allowedKeys: Set<String>,
        requiredKeys: Set<String>,
        role: String
    ) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw invalid("Could not parse \(role) JSON.")
        }
        guard let object = value as? [String: Any] else {
            throw invalid("The \(role) must be one JSON object.")
        }

        let orderedKeys = try topLevelKeys(in: data, role: role)
        var seen = Set<String>()
        if let duplicate = orderedKeys.first(where: { !seen.insert($0).inserted }) {
            let field = allowedKeys.contains(duplicate) ? " '\(duplicate)'" : ""
            throw invalid("The \(role) contains a duplicate field\(field).")
        }

        let actual = Set(object.keys)
        guard actual.isSubset(of: allowedKeys) else {
            throw invalid("The \(role) contains unsupported fields.")
        }
        guard requiredKeys.isSubset(of: actual) else {
            throw invalid("The \(role) is missing required fields.")
        }
    }

    private static func topLevelKeys(in data: Data, role: String) throws -> [String] {
        let bytes = Array(data)
        var index = skipWhitespace(in: bytes, from: 0)
        guard index < bytes.count, bytes[index] == ascii("{") else {
            throw invalid("The \(role) must be one JSON object.")
        }
        index += 1
        var keys: [String] = []

        while true {
            index = skipWhitespace(in: bytes, from: index)
            guard index < bytes.count else { throw invalid("Could not parse \(role) JSON.") }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }

            let key = try parseJSONString(in: bytes, from: index, role: role)
            keys.append(key.value)
            index = skipWhitespace(in: bytes, from: key.nextIndex)
            guard index < bytes.count, bytes[index] == ascii(":") else {
                throw invalid("Could not parse \(role) JSON.")
            }
            index = try skipJSONValue(in: bytes, from: index + 1, role: role)
            index = skipWhitespace(in: bytes, from: index)
            guard index < bytes.count else { throw invalid("Could not parse \(role) JSON.") }
            if bytes[index] == ascii(",") {
                index += 1
                continue
            }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }
            throw invalid("Could not parse \(role) JSON.")
        }
        guard skipWhitespace(in: bytes, from: index) == bytes.count else {
            throw invalid("Could not parse \(role) JSON.")
        }
        return keys
    }

    private static func parseJSONString(
        in bytes: [UInt8],
        from start: Int,
        role: String
    ) throws -> (value: String, nextIndex: Int) {
        guard start < bytes.count, bytes[start] == ascii("\"") else {
            throw invalid("Could not parse \(role) JSON object key.")
        }
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == ascii("\\") {
                escaped = true
            } else if byte == ascii("\"") {
                let literal = Data(bytes[start...index])
                guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                    throw invalid("Could not parse \(role) JSON object key.")
                }
                return (value, index + 1)
            }
            index += 1
        }
        throw invalid("Could not parse \(role) JSON object key.")
    }

    private static func skipJSONValue(in bytes: [UInt8], from start: Int, role: String) throws -> Int {
        var index = skipWhitespace(in: bytes, from: start)
        var objectDepth = 0
        var arrayDepth = 0
        var inString = false
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == ascii("\\") {
                    escaped = true
                } else if byte == ascii("\"") {
                    inString = false
                }
                index += 1
                continue
            }
            switch byte {
            case ascii("\""):
                inString = true
            case ascii("{"):
                objectDepth += 1
            case ascii("}"):
                if objectDepth == 0, arrayDepth == 0 { return index }
                objectDepth -= 1
            case ascii("["):
                arrayDepth += 1
            case ascii("]"):
                arrayDepth -= 1
            case ascii(",") where objectDepth == 0 && arrayDepth == 0:
                return index
            default:
                break
            }
            guard objectDepth >= 0, arrayDepth >= 0 else {
                throw invalid("Could not parse \(role) JSON.")
            }
            index += 1
        }
        throw invalid("Could not parse \(role) JSON.")
    }

    private static func skipWhitespace(in bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }

    private static func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .controlAPIInvalid, message: message)
    }
}

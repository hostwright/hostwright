import Foundation
import HostwrightCore
import HostwrightSecrets

public enum ManifestValidator {
    public static func validate(_ manifest: HostwrightManifest) -> [ManifestIssue] {
        var issues: [ManifestIssue] = []
        validateVersion(manifest.version, issues: &issues)

        if let project = manifest.project, !project.isEmpty {
            validateName(project, field: "project", issues: &issues)
        } else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Manifest must define a non-empty project."))
        }
        guard !manifest.services.isEmpty else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Manifest must define at least one service."))
            return issues
        }

        validateImageTrust(manifest, issues: &issues)
        validateImageSBOM(manifest, issues: &issues)
        validateImageVulnerability(manifest, issues: &issues)
        validateImageProvenance(manifest, issues: &issues)
        validateVolumeDeclarations(manifest.volumes, issues: &issues)

        let declaredNames = Set(manifest.services.map(\.name))
        let declaredVolumes = Set(manifest.volumes.keys)
        var serviceNames = Set<String>()
        for service in manifest.services {
            validateService(
                service,
                imagePolicy: manifest.effectiveImagePolicy,
                declaredNames: declaredNames,
                declaredVolumes: declaredVolumes,
                issues: &issues
            )
            if !serviceNames.insert(service.name).inserted {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Duplicate service name: \(service.name)."))
            }
        }
        validatePublishedPortCollisions(manifest.services, issues: &issues)
        return issues
    }

    public static func validated(_ text: String) throws -> HostwrightManifest {
        let manifest = try ManifestParser.parse(text)
        let issues = validate(manifest)
        if !issues.isEmpty {
            throw ManifestParseError.failed(issues)
        }
        return manifest
    }

    public static func validated(
        _ text: String,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> HostwrightManifest {
        let manifest = try ManifestParser.parse(text, cancellationCheck: cancellationCheck)
        let issues = validate(manifest)
        if !issues.isEmpty {
            throw ManifestParseError.failed(issues)
        }
        return manifest
    }

    private static func validateService(
        _ service: HostwrightService,
        imagePolicy: HostwrightImagePolicy,
        declaredNames: Set<String>,
        declaredVolumes: Set<String>,
        issues: inout [ManifestIssue]
    ) {
        validateName(service.name, field: "service name", issues: &issues)
        if !(1...256).contains(service.replicas) {
            issues.append(issue(service, "replicas must be between 1 and 256."))
        }

        if let image = service.image, !image.trimmingCharacters(in: .whitespaces).isEmpty {
            validateImage(image, serviceName: service.name, imagePolicy: imagePolicy, issues: &issues)
        } else {
            issues.append(issue(service, "must define a non-empty image."))
        }

        if let cpus = service.resources?.cpus, cpus <= 0 {
            issues.append(issue(service, "resources.cpus must be a positive integer."))
        }
        if let memory = service.resources?.memory {
            validateSize(memory, field: "resources.memory", service: service, issues: &issues)
        }
        if let shmSize = service.shmSize {
            validateSize(shmSize, field: "shmSize", service: service, issues: &issues)
        }

        if let workdir = service.workdir, !isNormalizedAbsoluteContainerPath(workdir) {
            issues.append(issue(service, "workdir must be a normalized absolute container path."))
        }
        validateCommand(service.entrypoint, field: "entrypoint", service: service, issues: &issues)
        validateCommand(service.command, field: "command", service: service, issues: &issues)

        for (dependency, _) in service.dependsOn.sorted(by: { $0.key < $1.key }) {
            validateName(dependency, field: "dependency name", issues: &issues)
            if dependency == service.name {
                issues.append(issue(service, "dependsOn must not reference the service itself."))
            } else if !declaredNames.contains(dependency) {
                issues.append(issue(service, "dependsOn references missing service '\(dependency)'."))
            }
        }

        for port in service.ports {
            validatePort(port, serviceName: service.name, issues: &issues)
        }
        if Set(service.ports).count != service.ports.count {
            issues.append(issue(service, "ports must not contain duplicates."))
        }
        for volume in service.volumes {
            validateVolume(volume, serviceName: service.name, issues: &issues)
        }
        for mount in service.mounts {
            validateMount(mount, serviceName: service.name, issues: &issues)
            if mount.kind == .volume,
               let source = mount.source,
               !declaredVolumes.contains(source) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(service.name)' volume mount source '\(source)' must reference a declared top-level volume."
                    )
                )
            }
        }

        for (key, value) in service.env.sorted(by: { $0.key < $1.key }) {
            validateEnvironmentKey(key, serviceName: service.name, issues: &issues)
            validateLiteralEnvironmentValue(key: key, value: value, serviceName: service.name, issues: &issues)
            validateBounded(value, maximum: 16_384, field: "env.\(key)", service: service, issues: &issues)
        }
        for (key, reference) in service.secretEnv.sorted(by: { $0.key < $1.key }) {
            validateEnvironmentKey(key, serviceName: service.name, issues: &issues)
            validateSecretEnvironmentReference(key: key, reference: reference, serviceName: service.name, issues: &issues)
            if service.env.keys.contains(key) {
                issues.append(issue(service, "environment key '\(key)' must not appear in both env and secretEnv."))
            }
        }
        validateLabels(service.labels, service: service, issues: &issues)

        if let health = service.health {
            validateHealth(health, serviceName: service.name, issues: &issues)
        }
        validateProbe(service.probes.startup, name: "startup", service: service, issues: &issues)
        validateProbe(service.probes.readiness, name: "readiness", service: service, issues: &issues)
        validateProbe(service.probes.liveness, name: "liveness", service: service, issues: &issues)

        if let restart = service.restart {
            validateRestart(restart, serviceName: service.name, issues: &issues)
        }
        validateUpdate(service.update, replicas: service.replicas, service: service, issues: &issues)
        validateHook(service.hooks.postStart, name: "postStart", service: service, issues: &issues)
        validateHook(service.hooks.preStop, name: "preStop", service: service, issues: &issues)

        if service.rosetta && service.platform.architecture != .amd64 {
            issues.append(issue(service, "rosetta requires platform.architecture amd64."))
        }
        if service.rosetta && !service.virtualization {
            issues.append(issue(service, "rosetta requires virtualization."))
        }
    }

    private static func validateVolumeDeclarations(
        _ volumes: [String: HostwrightVolumeDeclaration],
        issues: inout [ManifestIssue]
    ) {
        for (name, declaration) in volumes.sorted(by: { $0.key < $1.key }) {
            validateName(name, field: "volume name", issues: &issues)
            validateVolumeProvider(declaration.provider, volumeName: name, issues: &issues)
            validateVolumeCapacity(declaration.capacity, volumeName: name, issues: &issues)
            validateVolumeLabels(declaration.labels, volumeName: name, issues: &issues)
        }
    }

    private static func validateVersion(_ version: Int?, issues: inout [ManifestIssue]) {
        guard let version else {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest must declare version: \(HostwrightManifest.currentVersion). Run 'hostwright migrate preview' for legacy manifests."
                )
            )
            return
        }
        guard version != HostwrightManifest.currentVersion else { return }
        if version < HostwrightManifest.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(version) is older than supported version \(HostwrightManifest.currentVersion). Run 'hostwright migrate preview' to inspect the required conversion."
                )
            )
        } else {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(version) is newer than supported version \(HostwrightManifest.currentVersion). Upgrade requires a newer Hostwright release."
                )
            )
        }
    }

    private static func validateImageTrust(
        _ manifest: HostwrightManifest,
        issues: inout [ManifestIssue]
    ) {
        guard let imageTrust = manifest.imageTrust else {
            return
        }
        guard manifest.version == HostwrightManifest.currentVersion else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust is supported only in manifest version 2."
                )
            )
            return
        }
        if manifest.effectiveImagePolicy != .requireDigest {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust requires imagePolicy require-digest."
                )
            )
        }
        if imageTrust.version != HostwrightImageTrustPolicy.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.version must be 1."
                )
            )
        }
        if !(1...8).contains(imageTrust.threshold) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.threshold must be between 1 and 8."
                )
            )
        }
        if !(1...8).contains(imageTrust.authorities.count) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.authorities must contain between 1 and 8 authorities."
                )
            )
        }
        if imageTrust.threshold > imageTrust.authorities.count {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.threshold must not exceed the authority count."
                )
            )
        }
        if let trustedRoot = imageTrust.trustedRoot,
           !isNormalizedAbsoluteHostPath(trustedRoot) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.trustedRoot must be a normalized absolute host path."
                )
            )
        }
        let keylessAuthorities = imageTrust.authorities.filter { $0.type == .keyless }
        if !keylessAuthorities.isEmpty, imageTrust.trustedRoot == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.trustedRoot is required when any keyless authority is declared."
                )
            )
        }

        var authorityIDs = Set<String>()
        for authority in imageTrust.authorities {
            if !authorityIDs.insert(authority.id).inserted {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust authority ids must be unique; duplicate id '\(authority.id)'."
                    )
                )
            }
            validateImageTrustAuthority(authority, issues: &issues)
        }
    }

    private static func validateImageSBOM(
        _ manifest: HostwrightManifest,
        issues: inout [ManifestIssue]
    ) {
        guard let imageSBOM = manifest.imageSBOM else {
            return
        }
        guard manifest.version == HostwrightManifest.currentVersion else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageSBOM is supported only in manifest version 2."
                )
            )
            return
        }
        if manifest.effectiveImagePolicy != .requireDigest {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageSBOM requires imagePolicy require-digest."
                )
            )
        }
        if imageSBOM.version != HostwrightImageSBOMPolicy.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageSBOM.version must be 1."
                )
            )
        }
        if imageSBOM.formats.isEmpty ||
            imageSBOM.formats.count > 2 ||
            Set(imageSBOM.formats).count != imageSBOM.formats.count {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageSBOM.formats must contain between 1 and 2 unique formats."
                )
            )
        }
    }

    private static func validateImageVulnerability(
        _ manifest: HostwrightManifest,
        issues: inout [ManifestIssue]
    ) {
        guard let policy = manifest.imageVulnerability else {
            return
        }
        guard manifest.version == HostwrightManifest.currentVersion else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability is supported only in manifest version 2."
                )
            )
            return
        }
        if manifest.effectiveImagePolicy != .requireDigest {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability requires imagePolicy require-digest."
                )
            )
        }
        if manifest.imageTrust == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability requires imageTrust."
                )
            )
        }
        if policy.version != HostwrightImageVulnerabilityPolicy.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability.version must be 1."
                )
            )
        }
        if !(0...HostwrightImageVulnerabilityPolicy.maximumMinimumVulnerabilityAgeSeconds)
            .contains(policy.minimumVulnerabilityAgeSeconds) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability.minimumVulnerabilityAgeSeconds must be between 0 and \(HostwrightImageVulnerabilityPolicy.maximumMinimumVulnerabilityAgeSeconds)."
                )
            )
        }
        if policy.maximumDatabaseAgeSeconds <
            HostwrightImageVulnerabilityPolicy.minimumMaximumDatabaseAgeSeconds ||
            policy.maximumDatabaseAgeSeconds >
            HostwrightImageVulnerabilityPolicy.maximumMaximumDatabaseAgeSeconds {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability.maximumDatabaseAgeSeconds must be between \(HostwrightImageVulnerabilityPolicy.minimumMaximumDatabaseAgeSeconds) and \(HostwrightImageVulnerabilityPolicy.maximumMaximumDatabaseAgeSeconds)."
                )
            )
        }
        if policy.allowlist.count > HostwrightImageVulnerabilityPolicy.maximumAllowlistEntries {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability.allowlist must contain at most \(HostwrightImageVulnerabilityPolicy.maximumAllowlistEntries) entries."
                )
            )
        }

        var exactEntries = Set<String>()
        for entry in policy.allowlist {
            let exactKey = "\(entry.vulnerabilityID)\u{0}\(entry.packagePURL ?? "")"
            if !exactEntries.insert(exactKey).inserted {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability.allowlist entries must be unique by vulnerabilityID and packagePURL."
                    )
                )
            }
            if entry.vulnerabilityID.utf8.count > 128 ||
                entry.vulnerabilityID.range(
                    of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
                    options: .regularExpression
                ) == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability allowlist vulnerabilityID '\(entry.vulnerabilityID)' must be a bounded exact identifier."
                    )
                )
            }
            if let packagePURL = entry.packagePURL,
               !isExactPackagePURL(packagePURL) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability allowlist packagePURL must be a bounded exact package URL."
                    )
                )
            }
            if !isBoundedPolicyText(entry.reason, maximum: 512) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability allowlist reason must be a bounded non-empty string."
                    )
                )
            }
            if parseRFC3339(entry.expiresAt) == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability allowlist expiresAt must be an RFC3339 timestamp."
                    )
                )
            }
        }
    }

    private static func validateImageTrustAuthority(
        _ authority: HostwrightImageTrustAuthority,
        issues: inout [ManifestIssue]
    ) {
        if authority.id.range(
            of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$"#,
            options: .regularExpression
        ) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority id '\(authority.id)' must be a bounded safe identifier."
                )
            )
        }
        switch authority.type {
        case .keyed:
            if authority.publicKey == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyed authority '\(authority.id)' requires publicKey."
                    )
                )
            } else if let publicKey = authority.publicKey,
                      !isNormalizedAbsoluteHostPath(publicKey) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyed authority '\(authority.id)' publicKey must be a normalized absolute host path."
                    )
                )
            }
            if authority.issuer != nil || authority.identity != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyed authority '\(authority.id)' accepts only publicKey."
                    )
                )
            }
        case .keyless:
            if authority.publicKey != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyless authority '\(authority.id)' must not declare publicKey."
                    )
                )
            }
            if authority.issuer == nil || authority.identity == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyless authority '\(authority.id)' requires issuer and identity."
                    )
                )
            }
            if let issuer = authority.issuer, !isExactHTTPSURL(issuer) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyless authority '\(authority.id)' issuer must be an exact HTTPS URL."
                    )
                )
            }
            if let identity = authority.identity,
               !isBoundedIdentity(identity) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyless authority '\(authority.id)' identity must be a bounded non-empty string."
                    )
                )
            }
        }

        let notBefore = authority.notBefore.flatMap(parseRFC3339)
        let notAfter = authority.notAfter.flatMap(parseRFC3339)
        let revokedAt = authority.revokedAt.flatMap(parseRFC3339)
        if authority.notBefore != nil && notBefore == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notBefore must be an RFC3339 timestamp."
                )
            )
        }
        if authority.notAfter != nil && notAfter == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notAfter must be an RFC3339 timestamp."
                )
            )
        }
        if authority.revokedAt != nil && revokedAt == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' revokedAt must be an RFC3339 timestamp."
                )
            )
        }
        if let notBefore, let notAfter, notBefore > notAfter {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notBefore must not be after notAfter."
                )
            )
        }
        if let notAfter, let revokedAt, notAfter > revokedAt {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notAfter must not be after revokedAt."
                )
            )
        }
        if let notBefore, let revokedAt, notBefore > revokedAt {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notBefore must not be after revokedAt."
                )
            )
        }
    }

    private static func validateImageProvenance(
        _ manifest: HostwrightManifest,
        issues: inout [ManifestIssue]
    ) {
        guard let policy = manifest.imageProvenance else {
            return
        }
        guard manifest.version == HostwrightManifest.currentVersion else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance is supported only in manifest version 2."
                )
            )
            return
        }
        if manifest.effectiveImagePolicy != .requireDigest {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance requires imagePolicy require-digest."
                )
            )
        }
        if policy.version != HostwrightImageProvenancePolicy.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.version must be 1."
                )
            )
        }
        if !(1...HostwrightImageProvenancePolicy.maximumBuilderIDs)
            .contains(policy.builderIDs.count) ||
            Set(policy.builderIDs).count != policy.builderIDs.count {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.builderIDs must contain between 1 and \(HostwrightImageProvenancePolicy.maximumBuilderIDs) unique values."
                )
            )
        }
        for builderID in policy.builderIDs where !isBoundedProvenanceURI(builderID) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance builderID '\(builderID)' must be a bounded https:// or urn: URI."
                )
            )
        }
        if !(1...HostwrightImageProvenancePolicy.maximumBuildTypes)
            .contains(policy.buildTypes.count) ||
            Set(policy.buildTypes).count != policy.buildTypes.count {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.buildTypes must contain between 1 and \(HostwrightImageProvenancePolicy.maximumBuildTypes) unique values."
                )
            )
        }
        for buildType in policy.buildTypes where !isBoundedProvenanceURI(buildType) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance buildType '\(buildType)' must be a bounded https:// or urn: URI."
                )
            )
        }
        if !(1...HostwrightImageProvenancePolicy.maximumSigners).contains(policy.signers.count) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.signers must contain between 1 and \(HostwrightImageProvenancePolicy.maximumSigners) signers."
                )
            )
        }
        var signerIDs = Set<String>()
        for signer in policy.signers {
            if !signerIDs.insert(signer.id).inserted {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageProvenance signer ids must be unique; duplicate id '\(signer.id)'."
                    )
                )
            }
            validateImageProvenanceSigner(signer, issues: &issues)
        }
        if policy.maximumAgeSeconds <
            HostwrightImageProvenancePolicy.minimumMaximumAgeSeconds ||
            policy.maximumAgeSeconds >
            HostwrightImageProvenancePolicy.maximumMaximumAgeSeconds {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.maximumAgeSeconds must be between \(HostwrightImageProvenancePolicy.minimumMaximumAgeSeconds) and \(HostwrightImageProvenancePolicy.maximumMaximumAgeSeconds)."
                )
            )
        }
    }

    private static func validateImageProvenanceSigner(
        _ signer: HostwrightImageProvenanceSigner,
        issues: inout [ManifestIssue]
    ) {
        if signer.id.utf8.count > HostwrightImageProvenancePolicy.maximumSignerIDUTF8Bytes ||
            signer.id.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$"#,
                options: .regularExpression
            ) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer id '\(signer.id)' must be a bounded safe identifier."
                )
            )
        }
        if signer.publicKey.utf8.count > HostwrightImageProvenancePolicy.maximumPublicKeyUTF8Bytes ||
            signer.publicKey.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) ||
            !isNormalizedAbsoluteHostPath(signer.publicKey) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' publicKey must be a bounded normalized absolute host path."
                )
            )
        }

        let notBefore = signer.notBefore.flatMap(parseRFC3339)
        let notAfter = signer.notAfter.flatMap(parseRFC3339)
        let revokedAt = signer.revokedAt.flatMap(parseRFC3339)
        if signer.notBefore != nil && notBefore == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notBefore must be an RFC3339 timestamp."
                )
            )
        }
        if signer.notAfter != nil && notAfter == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notAfter must be an RFC3339 timestamp."
                )
            )
        }
        if signer.revokedAt != nil && revokedAt == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' revokedAt must be an RFC3339 timestamp."
                )
            )
        }
        if let notBefore, let notAfter, notBefore > notAfter {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notBefore must not be after notAfter."
                )
            )
        }
        if let notAfter, let revokedAt, notAfter > revokedAt {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notAfter must not be after revokedAt."
                )
            )
        }
        if let notBefore, let revokedAt, notBefore > revokedAt {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notBefore must not be after revokedAt."
                )
            )
        }
    }

    private static func validateName(_ value: String, field: String, issues: inout [ManifestIssue]) {
        let pattern = #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#
        if value.range(of: pattern, options: .regularExpression) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "\(field) '\(value)' must be lowercase DNS-like text: letters, numbers, hyphens, no leading or trailing hyphen."
                )
            )
        }
    }

    private static func validateImage(
        _ image: String,
        serviceName: String,
        imagePolicy: HostwrightImagePolicy,
        issues: inout [ManifestIssue]
    ) {
        if image.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' image must not contain whitespace."))
        }
        if image.hasPrefix("-") {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' image must not begin with '-'."))
        }
        issues.append(contentsOf: ImageReferencePolicy.validate(image, serviceName: serviceName, policy: imagePolicy))
    }

    private static func validateCommand(
        _ command: [String],
        field: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard command.count <= 1_024 else {
            issues.append(issue(service, "\(field) exceeds 1,024 arguments."))
            return
        }
        for token in command {
            if token.isEmpty {
                issues.append(issue(service, "\(field) tokens must not be empty."))
            } else {
                validateBounded(token, maximum: 16_384, field: field, service: service, issues: &issues)
            }
        }
    }

    private static func validatePort(_ port: String, serviceName: String, issues: inout [ManifestIssue]) {
        let parts = port.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let published = Int(parts[0]),
              let target = Int(parts[1]),
              isValidPort(published),
              isValidPort(target)
        else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' port '\(port)' must use \"host:container\" with ports between 1 and 65535."
                )
            )
            return
        }
    }

    private static func validatePublishedPortCollisions(
        _ services: [HostwrightService],
        issues: inout [ManifestIssue]
    ) {
        var ownersByPort: [Int: Set<String>] = [:]

        for service in services.sorted(by: { $0.name < $1.name }) {
            let publishedPorts = service.ports.compactMap(validPublishedPort)
            let uniquePorts = Set(publishedPorts)

            if service.replicas > 1, !uniquePorts.isEmpty {
                let ports = uniquePorts.sorted().map(String.init).joined(separator: ", ")
                issues.append(
                    issue(
                        service,
                        "replicas cannot share fixed localhost ports: \(ports)."
                    )
                )
            }

            for port in uniquePorts {
                ownersByPort[port, default: []].insert(service.name)
            }

            let counts = Dictionary(
                grouping: publishedPorts,
                by: { $0 }
            ).mapValues(\.count)
            for port in counts.keys.sorted() where counts[port, default: 0] > 1 {
                issues.append(
                    issue(
                        service,
                        "publishes fixed localhost port \(port) more than once."
                    )
                )
            }
        }

        for port in ownersByPort.keys.sorted() {
            let owners = ownersByPort[port, default: []].sorted()
            guard owners.count > 1 else { continue }
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Fixed localhost port \(port) is published by multiple services: \(owners.joined(separator: ", "))."
                )
            )
        }
    }

    private static func validPublishedPort(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let published = Int(parts[0]),
              let target = Int(parts[1]),
              isValidPort(published),
              isValidPort(target) else {
            return nil
        }
        return published
    }

    private static func validateVolume(_ volume: String, serviceName: String, issues: inout [ManifestIssue]) {
        let parts = volume.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[1].hasPrefix("/")
        else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' volume '\(volume)' must use source:/absolute/container/path[:ro|rw]."
                )
            )
            return
        }
        if parts.count == 3 && parts[2] != "ro" && parts[2] != "rw" {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' mode must be ro or rw."))
        }
        let source = String(parts[0])
        if HostwrightPathPolicy.isHostRootMountSource(source) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' must not mount the host root."))
        }
        if HostwrightPathPolicy.containsParentDirectoryTraversal(source) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' source must not contain parent-directory traversal."))
        }
        if !isNormalizedAbsoluteContainerPath(String(parts[1])) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' container path must be normalized."))
        }
    }

    private static func validateMount(
        _ mount: HostwrightMountSpec,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        let source = mount.source
        guard isNormalizedAbsoluteContainerPath(mount.target) else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' mount target '\(mount.target)' must be a normalized absolute container path."
                )
            )
            return
        }

        switch mount.kind {
        case .bind:
            guard let source, !source.isEmpty else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' bind mount requires source."
                    )
                )
                return
            }
            if HostwrightPathPolicy.isHostRootMountSource(source) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' bind mount source '\(source)' must not mount the host root."
                    )
                )
            }
            if HostwrightPathPolicy.containsParentDirectoryTraversal(source) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' bind mount source '\(source)' must not contain parent-directory traversal."
                    )
                )
            }
            if mount.mode != nil || mount.size != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' bind mounts accept only source, target, and readOnly."
                    )
                )
            }
        case .volume:
            guard let source, !source.isEmpty else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' volume mount requires source."
                    )
                )
                return
            }
            if source.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: String.CompareOptions.regularExpression) == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' volume mount source '\(source)' must be a bounded safe name."
                    )
                )
            }
            if mount.mode != nil || mount.size != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' volume mounts accept only source, target, and readOnly."
                    )
                )
            }
        case .tmpfs:
            if mount.source != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' tmpfs mounts must not declare source."
                    )
                )
            }
            if let size = mount.size {
                validateSize(size, field: "mount.size", service: HostwrightService(name: serviceName, image: nil), issues: &issues)
            }
            if let mode = mount.mode,
               mode.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' tmpfs mount mode must be a three- or four-digit octal string."
                    )
                )
            }
        }
    }

    private static func validateEnvironmentKey(_ key: String, serviceName: String, issues: inout [ManifestIssue]) {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        if key.range(of: pattern, options: .regularExpression) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' environment key '\(key)' must use shell-safe letters, numbers, and underscores, and must not start with a number."
                )
            )
        }
    }

    private static func validateLiteralEnvironmentValue(
        key: String,
        value: String,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        if HostwrightSecretProviderKind.allCases.contains(where: {
            value.hasPrefix("\($0.rawValue)://")
        }) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' environment key '\(key)' uses a secret reference in env; move it to secretEnv."
                )
            )
        }
        if SecretNamePolicy.requiresSecretReferenceEnvironmentKey(key) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' environment key '\(key)' looks sensitive; plaintext sensitive values must use secretEnv."
                )
            )
        }
    }

    private static func validateSecretEnvironmentReference(
        key: String,
        reference: HostwrightSecretReference,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        do {
            _ = try HostwrightSecretReference.parse(reference.rawValue)
        } catch {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' secretEnv key '\(key)' must use one of: keychain://<service>/<account>, env-file:///absolute/path#KEY, local-file:///absolute/path, external://<provider>/<item>, or plugin://<provider>/<item>."
                )
            )
        }
    }

    private static func validateLabels(
        _ labels: [String: String],
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        if labels.count > 256 {
            issues.append(issue(service, "labels exceed the limit of 256 entries."))
        }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("dev.hostwright.") {
                issues.append(issue(service, "label '\(key)' uses the reserved Hostwright ownership prefix."))
            }
            validateBounded(key, maximum: 128, field: "label key", service: service, issues: &issues)
            validateBounded(value, maximum: 4_096, field: "label '\(key)'", service: service, issues: &issues)
        }
    }

    private static func validateVolumeLabels(
        _ labels: [String: String],
        volumeName: String,
        issues: inout [ManifestIssue]
    ) {
        if labels.count > 256 {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' labels exceed the limit of 256 entries."
                )
            )
        }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("dev.hostwright.") {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Volume '\(volumeName)' label '\(key)' uses the reserved Hostwright ownership prefix."
                    )
                )
            }
            validateVolumeBounded(key, maximum: 128, field: "label key", volumeName: volumeName, issues: &issues)
            validateVolumeBounded(value, maximum: 4_096, field: "label '\(key)'", volumeName: volumeName, issues: &issues)
        }
    }

    private static func validateVolumeProvider(
        _ provider: String,
        volumeName: String,
        issues: inout [ManifestIssue]
    ) {
        validateVolumeBounded(provider, maximum: 128, field: "provider", volumeName: volumeName, issues: &issues)
        if provider.range(
            of: #"^[a-z0-9](?:[a-z0-9.-]{0,126}[a-z0-9])?$"#,
            options: .regularExpression
        ) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' provider '\(provider)' must be a bounded stable provider ID."
                )
            )
        }
    }

    private static func validateVolumeCapacity(
        _ capacity: String,
        volumeName: String,
        issues: inout [ManifestIssue]
    ) {
        let pattern = #"^[1-9][0-9]*(B|KiB|MiB|GiB|TiB)$"#
        guard capacity.range(of: pattern, options: .regularExpression) != nil else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' capacity must be a normalized positive size such as 512MiB."
                )
            )
            return
        }
        let suffixes: [(String, UInt64)] = [
            ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824),
            ("MiB", 1_048_576),
            ("KiB", 1_024),
            ("B", 1)
        ]
        guard let (suffix, multiplier) = suffixes.first(where: { capacity.hasSuffix($0.0) }),
              let count = UInt64(capacity.dropLast(suffix.count)),
              !count.multipliedReportingOverflow(by: multiplier).overflow else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' capacity exceeds UInt64 byte capacity."
                )
            )
            return
        }
    }

    private static func validateHealth(
        _ health: HostwrightHealthCheck,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        if health.command.isEmpty {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' health command must not be empty when health is present."))
        }
        if let interval = health.interval {
            validatePositiveDuration(interval, field: "health interval", serviceName: serviceName, issues: &issues)
        }
    }

    private static func validateProbe(
        _ probe: HostwrightProbe?,
        name: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard let probe else { return }
        switch probe.action {
        case .exec(let command):
            if command.isEmpty {
                issues.append(issue(service, "probes.\(name).exec must not be empty."))
            }
            validateCommand(command, field: "probes.\(name).exec", service: service, issues: &issues)
        case .http(let port, let path):
            validateProbePort(port, name: name, service: service, issues: &issues)
            if !isNormalizedAbsoluteContainerPath(path) {
                issues.append(issue(service, "probes.\(name).http.path must be a normalized absolute loopback path."))
            }
        case .tcp(let port):
            validateProbePort(port, name: name, service: service, issues: &issues)
        }
        if probe.startPeriod < 0 || probe.interval <= 0 || probe.timeout <= 0
            || probe.successThreshold <= 0 || probe.failureThreshold <= 0 {
            issues.append(issue(service, "probes.\(name) timing and thresholds must be positive; startPeriod may be zero."))
        }
    }

    private static func validateProbePort(
        _ port: Int,
        name: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        let declaredTargets = Set(service.ports.compactMap { value -> Int? in
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            return fields.count == 2 ? Int(fields[1]) : nil
        })
        if !isValidPort(port) || !declaredTargets.contains(port) {
            issues.append(issue(service, "probes.\(name) port \(port) must reference a declared service container port."))
        }
    }

    private static func validateRestart(
        _ restart: HostwrightRestart,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        let allowed = ["no", "on-failure", "unless-stopped"]
        if !allowed.contains(restart.policy) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart policy must be one of: \(allowed.joined(separator: ", "))."))
        }
    }

    private static func validateUpdate(
        _ update: HostwrightUpdatePolicy,
        replicas: Int,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        if update.maxSurge < 0 || update.maxUnavailable < 0 {
            issues.append(issue(service, "update maxSurge and maxUnavailable must be non-negative."))
        }
        if update.strategy == .rolling && update.maxSurge == 0 && update.maxUnavailable == 0 {
            issues.append(issue(service, "rolling update requires maxSurge or maxUnavailable to be positive."))
        }
        if update.maxUnavailable > replicas {
            issues.append(issue(service, "update.maxUnavailable must not exceed replicas."))
        }
        if update.progressDeadline <= 0 {
            issues.append(issue(service, "update.progressDeadline must be positive."))
        }
    }

    private static func validateHook(
        _ hook: [String]?,
        name: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard let hook else { return }
        if hook.isEmpty {
            issues.append(issue(service, "hooks.\(name).exec must not be empty."))
        }
        validateCommand(hook, field: "hooks.\(name).exec", service: service, issues: &issues)
    }

    private static func validateSize(
        _ value: String,
        field: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        let pattern = #"^[1-9][0-9]*(B|KiB|MiB|GiB|TiB)$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            issues.append(issue(service, "\(field) must be a normalized positive size such as 512MiB."))
            return
        }

        let suffixes: [(String, UInt64)] = [
            ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824),
            ("MiB", 1_048_576),
            ("KiB", 1_024),
            ("B", 1)
        ]
        guard let (suffix, multiplier) = suffixes.first(where: {
            value.hasSuffix($0.0)
        }),
            let count = UInt64(value.dropLast(suffix.count)),
            !count.multipliedReportingOverflow(by: multiplier).overflow else {
            issues.append(issue(service, "\(field) exceeds UInt64 byte capacity."))
            return
        }
    }

    private static func validateBounded(
        _ value: String,
        maximum: Int,
        field: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        if value.utf8.count > maximum {
            issues.append(issue(service, "\(field) exceeds \(maximum) UTF-8 bytes."))
        }
    }

    private static func validateVolumeBounded(
        _ value: String,
        maximum: Int,
        field: String,
        volumeName: String,
        issues: inout [ManifestIssue]
    ) {
        if value.utf8.count > maximum {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' \(field) exceeds \(maximum) UTF-8 bytes."
                )
            )
        }
    }

    private static func validatePositiveDuration(
        _ duration: String,
        field: String,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        guard duration.hasSuffix("s"),
              let seconds = Int(duration.dropLast()),
              seconds > 0,
              String(seconds) == duration.dropLast()
        else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' \(field) must be a positive seconds value like 10s."))
            return
        }
    }

    private static func isNormalizedAbsoluteContainerPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value != "/", !value.contains("//") else {
            return value == "/"
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isNormalizedAbsoluteHostPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"),
              value != "/",
              !value.contains("//"),
              !value.contains("/./"),
              !value.hasSuffix("/."),
              !value.contains("/../"),
              !value.hasSuffix("/..") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isExactHTTPSURL(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return components.url?.absoluteString == value
    }

    private static func isBoundedProvenanceURI(_ value: String) -> Bool {
        let hasAllowedScheme =
            (value.hasPrefix("https://") && value.utf8.count > "https://".utf8.count) ||
            (value.hasPrefix("urn:") && value.utf8.count > "urn:".utf8.count)
        return hasAllowedScheme &&
            value.utf8.count <= HostwrightImageProvenancePolicy.maximumURIUTF8Bytes &&
            value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
            !value.contains("@") &&
            !value.contains("..") &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isBoundedIdentity(_ value: String) -> Bool {
        !value.isEmpty &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.utf8.count <= 512 &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isExactPackagePURL(_ value: String) -> Bool {
        value.hasPrefix("pkg:") &&
            value.utf8.count <= 1_024 &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.dropFirst(4).contains("/") &&
            value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isBoundedPolicyText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximum &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func issue(_ service: HostwrightService, _ message: String) -> ManifestIssue {
        ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' \(message)")
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }
}

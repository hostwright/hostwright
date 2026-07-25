import Foundation
import HostwrightCore
import HostwrightRegistry

public struct ImageProvenanceRecord:
    Codable,
    Equatable,
    Sendable
{
    public let projectID: String
    public let serviceName: String
    public let descriptorDigest: String
    public let policySHA256: String
    public let statementDigest: String
    public let envelopeDigest: String
    public let referrerDigest: String
    public let evidenceDiscoveryID: String
    public let evidenceGraphSHA256: String
    public let sourceURI: String
    public let sourceDigest: String
    public let builderID: String
    public let builderVersion: String
    public let buildType: String
    public let invocationID: String
    public let normalizedMaterialsSHA256: String
    public let commandSHA256: String
    public let environmentPolicySHA256: String
    public let startedAt: String
    public let finishedAt: String
    public let reproducibilityStatus:
        ImageProvenanceReproducibilityStatus
    public let comparisonDigest: String?
    public let signerID: String
    public let signerPublicKeySHA256: String
    public let signatureSHA256: String
    public let verifierVersion: String
    public let verifiedAt: String
    public let operationGroupID: String
    public let createdAt: String

    public var id: String {
        HostwrightResourceUUID.legacy(
            kind: "image-provenance-record",
            identifier: [
                projectID,
                serviceName,
                descriptorDigest,
                policySHA256,
                statementDigest,
                envelopeDigest,
                referrerDigest,
                evidenceDiscoveryID,
                evidenceGraphSHA256,
                sourceURI,
                sourceDigest,
                builderID,
                builderVersion,
                buildType,
                invocationID,
                normalizedMaterialsSHA256,
                commandSHA256,
                environmentPolicySHA256,
                startedAt,
                finishedAt,
                reproducibilityStatus.rawValue,
                comparisonDigest ?? "",
                signerID,
                signerPublicKeySHA256,
                signatureSHA256,
                verifierVersion,
                verifiedAt
            ].joined(separator: "\u{1f}")
        )
    }

    public init(
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        policySHA256: String,
        statementDigest: String,
        envelopeDigest: String,
        referrerDigest: String,
        evidenceDiscoveryID: String,
        evidenceGraphSHA256: String,
        sourceURI: String,
        sourceDigest: String,
        builderID: String,
        builderVersion: String,
        buildType: String,
        invocationID: String,
        normalizedMaterialsSHA256: String,
        commandSHA256: String,
        environmentPolicySHA256: String,
        startedAt: String,
        finishedAt: String,
        reproducibilityStatus:
            ImageProvenanceReproducibilityStatus,
        comparisonDigest: String?,
        signerID: String,
        signerPublicKeySHA256: String,
        signatureSHA256: String,
        verifierVersion: String,
        verifiedAt: String,
        operationGroupID: String,
        createdAt: String
    ) {
        self.projectID = projectID
        self.serviceName = serviceName
        self.descriptorDigest = descriptorDigest
        self.policySHA256 = policySHA256
        self.statementDigest = statementDigest
        self.envelopeDigest = envelopeDigest
        self.referrerDigest = referrerDigest
        self.evidenceDiscoveryID = evidenceDiscoveryID
        self.evidenceGraphSHA256 = evidenceGraphSHA256
        self.sourceURI = sourceURI
        self.sourceDigest = sourceDigest
        self.builderID = builderID
        self.builderVersion = builderVersion
        self.buildType = buildType
        self.invocationID = invocationID
        self.normalizedMaterialsSHA256 =
            normalizedMaterialsSHA256
        self.commandSHA256 = commandSHA256
        self.environmentPolicySHA256 =
            environmentPolicySHA256
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.reproducibilityStatus = reproducibilityStatus
        self.comparisonDigest = comparisonDigest
        self.signerID = signerID
        self.signerPublicKeySHA256 =
            signerPublicKeySHA256
        self.signatureSHA256 = signatureSHA256
        self.verifierVersion = verifierVersion
        self.verifiedAt = verifiedAt
        self.operationGroupID = operationGroupID
        self.createdAt = createdAt
    }

    public init(
        projectID: String,
        serviceName: String,
        referrerDigest: String,
        evidenceDiscoveryID: String,
        evidenceGraphSHA256: String,
        verification: ImageProvenanceVerification,
        operationGroupID: String,
        createdAt: String
    ) {
        let statement = verification.statement
        self.init(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest:
                statement.subjectDigest.canonicalValue,
            policySHA256: verification.policySHA256,
            statementDigest:
                statement.statementDigest.canonicalValue,
            envelopeDigest:
                verification.envelopeDigest.canonicalValue,
            referrerDigest: referrerDigest,
            evidenceDiscoveryID: evidenceDiscoveryID,
            evidenceGraphSHA256: evidenceGraphSHA256,
            sourceURI: statement.source.uri,
            sourceDigest:
                statement.source.digest.canonicalValue,
            builderID: statement.builderID,
            builderVersion: statement.builderVersion,
            buildType: statement.buildType,
            invocationID: statement.invocationID,
            normalizedMaterialsSHA256:
                statement.normalizedMaterialsSHA256,
            commandSHA256: statement.commandSHA256,
            environmentPolicySHA256:
                statement.environmentPolicySHA256,
            startedAt: statement.startedAt,
            finishedAt: statement.finishedAt,
            reproducibilityStatus:
                statement.reproducibility.status,
            comparisonDigest: statement.reproducibility
                .comparisonDigest?.canonicalValue,
            signerID: verification.signerID,
            signerPublicKeySHA256:
                verification.signerPublicKeySHA256,
            signatureSHA256: verification.signatureSHA256,
            verifierVersion:
                ImageProvenanceVerification.verifierVersion,
            verifiedAt: verification.verifiedAt,
            operationGroupID: operationGroupID,
            createdAt: createdAt
        )
    }
}

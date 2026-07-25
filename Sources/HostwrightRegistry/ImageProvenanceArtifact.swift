import Foundation

public struct ImageProvenanceArtifact:
    Equatable,
    Sendable
{
    public static let emptyConfigMediaType =
        "application/vnd.oci.empty.v1+json"

    public let envelope: ImageProvenanceDSSEEnvelope
    public let envelopePayload: Data
    public let subjectDescriptor: OCIContentDescriptor
    public let rootDescriptor: OCIReferrerDescriptor
    public let graph: OCIReferrerGraph

    public static func make(
        envelopePayload: Data,
        subjectDescriptor: OCIContentDescriptor,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName
    ) throws -> ImageProvenanceArtifact {
        guard subjectDescriptor.digest.algorithm == "sha256",
              OCIImageSubjectMediaType.values.contains(
                  subjectDescriptor.mediaType
              ) else {
            throw ImageProvenanceError.subjectDigestMismatch
        }
        let envelope = try ImageProvenanceDSSEEnvelope.parse(
            envelopePayload,
            expectedSubjectDigest: subjectDescriptor.digest
        )
        let configPayload = Data("{}".utf8)
        let configDigest = try OCIContentDigest.sha256(
            of: configPayload
        )
        let configDescriptor = try OCIContentDescriptor(
            mediaType: emptyConfigMediaType,
            digest: configDigest,
            size: configPayload.count
        )
        let envelopeDescriptor = try OCIContentDescriptor(
            mediaType:
                ImageProvenanceDSSEEnvelope.layerMediaType,
            digest: envelope.envelopeDigest,
            size: envelopePayload.count,
            annotations: [
                "org.opencontainers.image.title":
                    "hostwright-image-provenance.dsse.json"
            ]
        )
        let annotations = [
            "org.opencontainers.image.created":
                "1970-01-01T00:00:00Z",
            "org.hostwright.image.digest":
                subjectDescriptor.digest.canonicalValue,
            "org.hostwright.provenance.statement.digest":
                envelope.statement.statementDigest
                    .canonicalValue,
            "org.hostwright.provenance.predicate-type":
                ImageProvenanceStatement.predicateType,
            "org.hostwright.provenance.signer-id":
                envelope.signerID
        ]
        let artifactType = try OCIArtifactType(
            ImageProvenanceDSSEEnvelope.artifactType
        )
        let manifestObject: [String: Any] = [
            "schemaVersion": 2,
            "mediaType":
                OCIReferrerDescriptor.manifestMediaType,
            "artifactType": artifactType.value,
            "config": imageProvenanceDescriptorObject(
                configDescriptor
            ),
            "layers": [
                imageProvenanceDescriptorObject(
                    envelopeDescriptor
                )
            ],
            "subject": imageProvenanceDescriptorObject(
                subjectDescriptor
            ),
            "annotations": annotations
        ]
        guard JSONSerialization.isValidJSONObject(
            manifestObject
        ) else {
            throw ImageProvenanceError.invalidEnvelope
        }
        let manifestPayload = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let manifestDigest = try OCIContentDigest.sha256(
            of: manifestPayload
        )
        let rootDescriptor = try OCIReferrerDescriptor(
            mediaType:
                OCIReferrerDescriptor.manifestMediaType,
            digest: manifestDigest,
            size: manifestPayload.count,
            artifactType: artifactType,
            annotations: annotations
        )
        let objects = [
            try OCIReferrerFetchedObject(
                digest: manifestDigest,
                mediaType:
                    OCIReferrerDescriptor.manifestMediaType,
                size: manifestPayload.count,
                kind: .manifest,
                payload: manifestPayload,
                childDescriptors: [
                    configDescriptor,
                    envelopeDescriptor
                ]
            ),
            try OCIReferrerFetchedObject(
                digest: configDigest,
                mediaType: emptyConfigMediaType,
                size: configPayload.count,
                kind: .blob,
                payload: configPayload,
                childDescriptors: []
            ),
            try OCIReferrerFetchedObject(
                digest: envelope.envelopeDigest,
                mediaType:
                    ImageProvenanceDSSEEnvelope.layerMediaType,
                size: envelopePayload.count,
                kind: .blob,
                payload: envelopePayload,
                childDescriptors: []
            )
        ]
        let discovery = OCIReferrerDiscoveryResult(
            endpoint: endpoint,
            repository: repository,
            subjectDigest: subjectDescriptor.digest,
            artifactType: artifactType,
            mode: .generated,
            serverFilterApplied: false,
            pageCount: 1,
            descriptors: [rootDescriptor],
            etag: nil
        )
        return ImageProvenanceArtifact(
            envelope: envelope,
            envelopePayload: envelopePayload,
            subjectDescriptor: subjectDescriptor,
            rootDescriptor: rootDescriptor,
            graph: try OCIReferrerGraph(
                discovery: discovery,
                verifiedReferrers: [rootDescriptor],
                objects: objects
            )
        )
    }
}

private func imageProvenanceDescriptorObject(
    _ descriptor: OCIContentDescriptor
) -> [String: Any] {
    var result: [String: Any] = [
        "mediaType": descriptor.mediaType,
        "digest": descriptor.digest.canonicalValue,
        "size": descriptor.size
    ]
    if !descriptor.annotations.isEmpty {
        result["annotations"] = descriptor.annotations
    }
    return result
}

import Foundation

public struct ImageProvenanceEvidence:
    Equatable,
    Sendable
{
    public let rootDescriptor: OCIReferrerDescriptor
    public let envelopeDescriptor: OCIContentDescriptor
    public let envelopePayload: Data
    public let envelope: ImageProvenanceDSSEEnvelope

    public var referrerDigest: OCIContentDigest {
        rootDescriptor.digest
    }
}

public enum ImageProvenanceEvidenceExtractor {
    public static func extract(
        from graph: OCIReferrerGraph,
        expectedSubjectDigest: OCIContentDigest
    ) throws -> [ImageProvenanceEvidence] {
        guard expectedSubjectDigest.algorithm == "sha256",
              graph.discovery.subjectDigest ==
                expectedSubjectDigest else {
            throw ImageProvenanceError.subjectDigestMismatch
        }
        var objects:
            [OCIContentDigest: OCIReferrerFetchedObject] = [:]
        for object in graph.objects {
            guard objects[object.digest] == nil else {
                throw ImageProvenanceError.invalidEnvelope
            }
            objects[object.digest] = object
        }
        var rootDigests = Set<OCIContentDigest>()
        var envelopeDigests = Set<OCIContentDigest>()
        var evidence: [ImageProvenanceEvidence] = []
        for root in graph.verifiedReferrers where
            root.artifactType?.value ==
                ImageProvenanceDSSEEnvelope.artifactType
        {
            guard rootDigests.insert(root.digest).inserted,
                  graph.discovery.descriptors.contains(root),
                  root.mediaType ==
                    OCIReferrerDescriptor.manifestMediaType,
                  let rootObject = objects[root.digest],
                  rootObject.kind == .manifest,
                  rootObject.mediaType == root.mediaType,
                  rootObject.size == root.size else {
                throw ImageProvenanceError.invalidEnvelope
            }
            let parsed: OCIParsedDocument
            do {
                parsed = try OCIParsedDocument.parse(
                    rootObject.payload
                )
            } catch {
                throw ImageProvenanceError.invalidEnvelope
            }
            guard parsed.subject?.digest ==
                    expectedSubjectDigest,
                  parsed.subject.map({
                      OCIImageSubjectMediaType.values.contains(
                          $0.mediaType
                      )
                  }) == true,
                  parsed.effectiveArtifactType?.value ==
                    ImageProvenanceDSSEEnvelope.artifactType,
                  rootObject.childDescriptors ==
                    parsed.children,
                  parsed.annotations[
                    "org.hostwright.image.digest"
                  ] == expectedSubjectDigest.canonicalValue,
                  parsed.annotations[
                    "org.hostwright.provenance.predicate-type"
                  ] == ImageProvenanceStatement.predicateType
            else {
                throw ImageProvenanceError
                    .subjectDigestMismatch
            }
            let candidates = parsed.children.filter {
                $0.mediaType ==
                    ImageProvenanceDSSEEnvelope.layerMediaType
            }
            guard candidates.count == 1,
                  let descriptor = candidates.first,
                  descriptor.digest.algorithm == "sha256",
                  envelopeDigests.insert(
                      descriptor.digest
                  ).inserted,
                  let object = objects[descriptor.digest],
                  object.kind == .blob,
                  object.mediaType == descriptor.mediaType,
                  object.size == descriptor.size else {
                throw ImageProvenanceError.invalidEnvelope
            }
            let envelope =
                try ImageProvenanceDSSEEnvelope.parse(
                    object.payload,
                    expectedSubjectDigest:
                        expectedSubjectDigest
                )
            guard envelope.envelopeDigest ==
                    descriptor.digest,
                  parsed.annotations[
                    "org.hostwright.provenance.statement.digest"
                  ] == envelope.statement.statementDigest
                    .canonicalValue,
                  parsed.annotations[
                    "org.hostwright.provenance.signer-id"
                  ] == envelope.signerID else {
                throw ImageProvenanceError.invalidEnvelope
            }
            evidence.append(
                ImageProvenanceEvidence(
                    rootDescriptor: root,
                    envelopeDescriptor: descriptor,
                    envelopePayload: object.payload,
                    envelope: envelope
                )
            )
        }
        guard !evidence.isEmpty else {
            throw ImageProvenanceError.invalidEnvelope
        }
        return evidence.sorted {
            $0.referrerDigest.canonicalValue <
                $1.referrerDigest.canonicalValue
        }
    }
}

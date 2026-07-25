import Foundation

public struct ImageSBOMEvidence: Equatable, Sendable {
    public let rootDescriptor: OCIReferrerDescriptor
    public let document: ImageSBOMDocument
    public let documentPayload: Data
    public let provenanceDescriptorDigest: OCIContentDigest?
    public let provenanceReferrerDigest: OCIContentDigest?
}

public enum ImageSBOMEvidenceExtractor {
    public static func extract(
        from graph: OCIReferrerGraph,
        expectedSubjectDigest: OCIContentDigest,
        allowedFormats: Set<ImageSBOMFormat>
    ) throws -> [ImageSBOMEvidence] {
        guard graph.discovery.subjectDigest ==
                expectedSubjectDigest,
              !allowedFormats.isEmpty else {
            throw ImageSBOMError.subjectDigestMismatch
        }
        let objects = Dictionary(
            uniqueKeysWithValues: graph.objects.map {
                ($0.digest, $0)
            }
        )
        var evidence: [ImageSBOMEvidence] = []
        for root in graph.verifiedReferrers {
            guard let artifactType = root.artifactType?.value,
                  let format = ImageSBOMFormat.allCases.first(
                      where: { $0.artifactType == artifactType }
                  ),
                  allowedFormats.contains(format),
                  let rootObject = objects[root.digest],
                  rootObject.kind == .manifest else {
                continue
            }
            let parsed: OCIParsedDocument
            do {
                parsed = try OCIParsedDocument.parse(
                    rootObject.payload
                )
            } catch {
                throw ImageSBOMError.invalidDocument
            }
            guard parsed.subject?.digest == expectedSubjectDigest,
                  parsed.subject.map({
                      OCIImageSubjectMediaType.values.contains(
                          $0.mediaType
                      )
                  }) == true,
                  parsed.effectiveArtifactType?.value ==
                    format.artifactType,
                  parsed.annotations[
                    "org.hostwright.image.digest"
                  ] == expectedSubjectDigest.canonicalValue,
                  parsed.annotations[
                    "org.hostwright.sbom.format"
                  ] == format.rawValue else {
                throw ImageSBOMError.subjectDigestMismatch
            }
            let candidates = parsed.children.filter {
                $0.mediaType == format.layerMediaType
            }
            guard candidates.count == 1,
                  let descriptor = candidates.first,
                  let documentObject = objects[descriptor.digest],
                  documentObject.kind == .blob,
                  documentObject.mediaType == descriptor.mediaType,
                  documentObject.size == descriptor.size else {
                throw ImageSBOMError.invalidDocument
            }
            let document = try ImageSBOMDocument.parse(
                documentObject.payload,
                expectedSubjectDigest: expectedSubjectDigest,
                expectedFormat: format
            )
            guard document.documentDigest == descriptor.digest,
                  parsed.annotations[
                    "org.hostwright.sbom.normalized-components-sha256"
                  ] == document.normalizedComponentsSHA256 else {
                throw ImageSBOMError.invalidDocument
            }
            let provenanceDescriptorRaw =
                parsed.annotations[
                    "org.hostwright.provenance.descriptor-digest"
                ]
            let provenanceReferrerRaw =
                parsed.annotations[
                    "org.hostwright.provenance.referrer-digest"
                ]
            guard (provenanceDescriptorRaw == nil) ==
                    (provenanceReferrerRaw == nil) else {
                throw ImageSBOMError.invalidDocument
            }
            let provenanceDescriptor =
                try provenanceDescriptorRaw.map(
                    OCIContentDigest.init
                )
            let provenanceReferrer =
                try provenanceReferrerRaw.map(
                    OCIContentDigest.init
                )
            evidence.append(
                ImageSBOMEvidence(
                    rootDescriptor: root,
                    document: document,
                    documentPayload: documentObject.payload,
                    provenanceDescriptorDigest:
                        provenanceDescriptor,
                    provenanceReferrerDigest:
                        provenanceReferrer
                )
            )
        }
        guard !evidence.isEmpty else {
            throw ImageSBOMError.unsupportedFormat
        }
        let sorted = evidence.sorted {
            $0.rootDescriptor.digest.canonicalValue <
                $1.rootDescriptor.digest.canonicalValue
        }
        guard Set(
            sorted.map { $0.rootDescriptor.digest }
        ).count == sorted.count else {
            throw ImageSBOMError.invalidDocument
        }
        return sorted
    }
}

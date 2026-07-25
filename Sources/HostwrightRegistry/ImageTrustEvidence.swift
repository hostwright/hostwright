import Foundation

public enum ImageTrustEvidenceError: Error, Equatable, Sendable {
    case invalidGraph
    case unsupportedArtifact
    case ambiguousBundle
}

public enum ImageTrustEvidenceExtractor {
    public static func bundles(
        from graph: OCIReferrerGraph
    ) throws -> [SigstoreBundleEvidence] {
        let objects = Dictionary(
            uniqueKeysWithValues: graph.objects.map {
                ($0.digest, $0)
            }
        )
        var bundles: [SigstoreBundleEvidence] = []
        for descriptor in graph.verifiedReferrers where
            descriptor.artifactType?.value ==
                SigstoreBundleEvidence.mediaType
        {
            guard descriptor.mediaType ==
                    OCIReferrerDescriptor.manifestMediaType,
                  let root = objects[descriptor.digest],
                  root.kind == .manifest,
                  root.mediaType == descriptor.mediaType else {
                throw ImageTrustEvidenceError.unsupportedArtifact
            }
            let candidates = root.childDescriptors.filter {
                $0.mediaType == SigstoreBundleEvidence.mediaType
            }
            guard candidates.count == 1,
                  let candidate = candidates.first,
                  let object = objects[candidate.digest],
                  object.kind == .blob,
                  object.mediaType == candidate.mediaType,
                  object.size == candidate.size else {
                throw ImageTrustEvidenceError.ambiguousBundle
            }
            do {
                bundles.append(
                    try SigstoreBundleEvidence(
                        digest: object.digest.canonicalValue,
                        payload: object.payload
                    )
                )
            } catch {
                throw ImageTrustEvidenceError.invalidGraph
            }
        }
        guard !bundles.isEmpty else {
            throw ImageTrustEvidenceError.unsupportedArtifact
        }
        let sorted = bundles.sorted { $0.digest < $1.digest }
        guard Set(sorted.map(\.digest)).count == sorted.count else {
            throw ImageTrustEvidenceError.invalidGraph
        }
        return sorted
    }
}

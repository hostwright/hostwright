import Foundation

enum OCIImageSubjectMediaType {
    static let values = Set([
        OCIReferrerDescriptor.manifestMediaType,
        OCIReferrerDescriptor.indexMediaType,
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.docker.distribution.manifest.list.v2+json"
    ])
}

public struct ImageSBOMArtifact: Equatable, Sendable {
    public static let emptyConfigMediaType =
        "application/vnd.oci.empty.v1+json"

    public let document: ImageSBOMDocument
    public let documentPayload: Data
    public let subjectDescriptor: OCIContentDescriptor
    public let rootDescriptor: OCIReferrerDescriptor
    public let graph: OCIReferrerGraph
    public let provenanceDescriptorDigest: OCIContentDigest?
    public let provenanceReferrerDigest: OCIContentDigest?

    public static func make(
        documentPayload: Data,
        expectedFormat: ImageSBOMFormat,
        subjectDescriptor: OCIContentDescriptor,
        endpoint: RegistryEndpoint,
        repository: OCIRepositoryName,
        provenanceDescriptorDigest: OCIContentDigest? = nil,
        provenanceReferrerDigest: OCIContentDigest? = nil
    ) throws -> ImageSBOMArtifact {
        guard subjectDescriptor.digest.algorithm == "sha256",
              OCIImageSubjectMediaType.values.contains(
                  subjectDescriptor.mediaType
              ),
              provenanceDescriptorDigest.map({
                  $0.algorithm == "sha256"
              }) ?? true,
              provenanceReferrerDigest.map({
                  $0.algorithm == "sha256"
              }) ?? true,
              (provenanceDescriptorDigest == nil) ==
                (provenanceReferrerDigest == nil) else {
            throw ImageSBOMError.invalidDocument
        }
        let document = try ImageSBOMDocument.parse(
            documentPayload,
            expectedSubjectDigest: subjectDescriptor.digest,
            expectedFormat: expectedFormat
        )
        let configPayload = Data("{}".utf8)
        let configDigest = try OCIContentDigest.sha256(of: configPayload)
        let configDescriptor = try OCIContentDescriptor(
            mediaType: emptyConfigMediaType,
            digest: configDigest,
            size: configPayload.count
        )
        let documentDescriptor = try OCIContentDescriptor(
            mediaType: expectedFormat.layerMediaType,
            digest: document.documentDigest,
            size: documentPayload.count,
            annotations: [
                "org.opencontainers.image.title":
                    "hostwright-image-sbom.\(expectedFormat.rawValue).json"
            ]
        )
        var annotations = [
            "org.opencontainers.image.created":
                "1970-01-01T00:00:00Z",
            "org.hostwright.image.digest":
                subjectDescriptor.digest.canonicalValue,
            "org.hostwright.sbom.format": expectedFormat.rawValue,
            "org.hostwright.sbom.normalized-components-sha256":
                document.normalizedComponentsSHA256
        ]
        if let provenanceDescriptorDigest,
           let provenanceReferrerDigest {
            annotations["org.hostwright.provenance.descriptor-digest"] =
                provenanceDescriptorDigest.canonicalValue
            annotations["org.hostwright.provenance.referrer-digest"] =
                provenanceReferrerDigest.canonicalValue
        }
        let artifactType = try OCIArtifactType(
            expectedFormat.artifactType
        )
        let manifestObject: [String: Any] = [
            "schemaVersion": 2,
            "mediaType": OCIReferrerDescriptor.manifestMediaType,
            "artifactType": artifactType.value,
            "config": descriptorObject(configDescriptor),
            "layers": [descriptorObject(documentDescriptor)],
            "subject": descriptorObject(subjectDescriptor),
            "annotations": annotations
        ]
        guard JSONSerialization.isValidJSONObject(manifestObject) else {
            throw ImageSBOMError.invalidDocument
        }
        let manifestPayload = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let manifestDigest = try OCIContentDigest.sha256(
            of: manifestPayload
        )
        let rootDescriptor = try OCIReferrerDescriptor(
            mediaType: OCIReferrerDescriptor.manifestMediaType,
            digest: manifestDigest,
            size: manifestPayload.count,
            artifactType: artifactType,
            annotations: annotations
        )
        let objects = [
            try OCIReferrerFetchedObject(
                digest: manifestDigest,
                mediaType: OCIReferrerDescriptor.manifestMediaType,
                size: manifestPayload.count,
                kind: .manifest,
                payload: manifestPayload,
                childDescriptors: [
                    configDescriptor, documentDescriptor
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
                digest: document.documentDigest,
                mediaType: expectedFormat.layerMediaType,
                size: documentPayload.count,
                kind: .blob,
                payload: documentPayload,
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
        let graph = try OCIReferrerGraph(
            discovery: discovery,
            verifiedReferrers: [rootDescriptor],
            objects: objects
        )
        return ImageSBOMArtifact(
            document: document,
            documentPayload: documentPayload,
            subjectDescriptor: subjectDescriptor,
            rootDescriptor: rootDescriptor,
            graph: graph,
            provenanceDescriptorDigest: provenanceDescriptorDigest,
            provenanceReferrerDigest: provenanceReferrerDigest
        )
    }
}

private func descriptorObject(
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

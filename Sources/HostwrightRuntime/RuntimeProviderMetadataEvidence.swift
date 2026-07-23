import Foundation

public enum RuntimeProviderMetadataEvidenceError: Error, Equatable, Sendable {
    case encodedEvidenceTooLarge
    case invalidJSONStringArray
    case tooManyEntries
    case entryTooLarge
    case malformedReservedEvidence
    case duplicateReservedEvidence
    case incompleteReservedEvidence
}

public struct RuntimeProviderMetadataEvidence: Equatable, Sendable {
    public static let currentRevision = 2
    public static let legacyRevision = 1
    public static let maximumEncodedBytes = 128 * 1_024
    public static let maximumEntryCount = 64
    public static let maximumEntryBytes = 256

    public static let capabilitySHA256MarkerPrefix = "hostwright.provider-capability.sha256="
    public static let providerMetadataRevisionMarkerPrefix = "hostwright.provider-metadata.revision="

    public let capabilitySHA256: String?
    public let providerMetadataRevision: Int
    public let isLegacy: Bool

    private init(
        capabilitySHA256: String?,
        providerMetadataRevision: Int,
        isLegacy: Bool
    ) {
        self.capabilitySHA256 = capabilitySHA256
        self.providerMetadataRevision = providerMetadataRevision
        self.isLegacy = isLegacy
    }

    public static func parse(capabilitiesJSON: String) throws -> Self {
        let data = Data(capabilitiesJSON.utf8)
        guard data.count <= maximumEncodedBytes else {
            throw RuntimeProviderMetadataEvidenceError.encodedEvidenceTooLarge
        }

        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RuntimeProviderMetadataEvidenceError.invalidJSONStringArray
        }
        guard let entries = decoded as? [String] else {
            throw RuntimeProviderMetadataEvidenceError.invalidJSONStringArray
        }
        return try parse(entries: entries)
    }

    public static func parse(entries: [String]) throws -> Self {
        try validateBounds(entries)

        var capabilitySHA256: String?
        var capabilityIndex: Int?
        var revision: Int?
        var revisionIndex: Int?

        for (index, entry) in entries.enumerated() {
            if entry.hasPrefix(capabilitySHA256MarkerPrefix) {
                guard capabilitySHA256 == nil else {
                    throw RuntimeProviderMetadataEvidenceError.duplicateReservedEvidence
                }
                let value = String(entry.dropFirst(capabilitySHA256MarkerPrefix.count))
                guard isCanonicalSHA256(value) else {
                    throw RuntimeProviderMetadataEvidenceError.malformedReservedEvidence
                }
                capabilitySHA256 = value
                capabilityIndex = index
                continue
            }

            if entry.hasPrefix(providerMetadataRevisionMarkerPrefix) {
                guard revision == nil else {
                    throw RuntimeProviderMetadataEvidenceError.duplicateReservedEvidence
                }
                let value = String(entry.dropFirst(providerMetadataRevisionMarkerPrefix.count))
                guard let parsedRevision = canonicalRevision(value) else {
                    throw RuntimeProviderMetadataEvidenceError.malformedReservedEvidence
                }
                revision = parsedRevision
                revisionIndex = index
                continue
            }

            if isReserved(entry) {
                throw RuntimeProviderMetadataEvidenceError.malformedReservedEvidence
            }
        }

        switch (capabilitySHA256, revision) {
        case (nil, nil):
            return Self(
                capabilitySHA256: nil,
                providerMetadataRevision: legacyRevision,
                isLegacy: true
            )
        case (.some(let capabilitySHA256), .some(let revision)):
            guard capabilityIndex == entries.count - 2,
                  revisionIndex == entries.count - 1 else {
                throw RuntimeProviderMetadataEvidenceError.malformedReservedEvidence
            }
            return Self(
                capabilitySHA256: capabilitySHA256,
                providerMetadataRevision: revision,
                isLegacy: false
            )
        case (.some, nil), (nil, .some):
            throw RuntimeProviderMetadataEvidenceError.incompleteReservedEvidence
        }
    }

    public static func appendingCurrentEvidence(
        to capabilityNames: [String],
        capabilitySHA256: String?
    ) throws -> [String] {
        try validateBounds(capabilityNames)
        guard capabilityNames.allSatisfy({ !isReserved($0) }) else {
            throw RuntimeProviderMetadataEvidenceError.malformedReservedEvidence
        }
        guard let capabilitySHA256 else {
            return capabilityNames
        }
        guard isCanonicalSHA256(capabilitySHA256) else {
            throw RuntimeProviderMetadataEvidenceError.malformedReservedEvidence
        }

        let entries = capabilityNames + [
            capabilitySHA256MarkerPrefix + capabilitySHA256,
            providerMetadataRevisionMarkerPrefix + String(currentRevision)
        ]
        try validateBounds(entries)
        return entries
    }

    private static func validateBounds(_ entries: [String]) throws {
        guard entries.count <= maximumEntryCount else {
            throw RuntimeProviderMetadataEvidenceError.tooManyEntries
        }
        guard entries.allSatisfy({ $0.utf8.count <= maximumEntryBytes }) else {
            throw RuntimeProviderMetadataEvidenceError.entryTooLarge
        }
    }

    private static func isReserved(_ entry: String) -> Bool {
        entry.hasPrefix("hostwright.provider-capability.") ||
            entry.hasPrefix("hostwright.provider-metadata.")
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func canonicalRevision(_ value: String) -> Int? {
        guard !value.isEmpty,
              value.utf8.count <= 9,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let revision = Int(value),
              revision > 0,
              String(revision) == value else {
            return nil
        }
        return revision
    }
}

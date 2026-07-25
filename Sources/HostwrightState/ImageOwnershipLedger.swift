import CryptoKit
import Foundation
import HostwrightRuntime

public enum ImageOwnershipChangeAction: String, Codable, Equatable, Sendable {
    case add
    case remove
}

public enum ImageOwnershipMetadataLimits {
    public static let maximumMetadataBytes = 64 * 1_024
    public static let maximumChanges = 256
    public static let maximumReferenceBytes = RuntimeImageLifecycleLimits.maximumReferenceBytes
    public static let maximumProviderIDBytes = RuntimeImageLifecycleLimits.maximumProviderValueBytes
}

public struct ImageOwnershipChangeV1: Codable, Equatable, Hashable, Sendable {
    public let action: ImageOwnershipChangeAction
    public let reference: String
    public let digest: String
    public let providerID: String

    public init(
        action: ImageOwnershipChangeAction,
        reference: String,
        digest: String,
        providerID: String
    ) throws {
        guard ImageOwnershipValidation.validReference(reference) else {
            throw StateStoreError.invalidRecord(
                "Image ownership reference must be one bounded normalized OCI reference."
            )
        }
        guard ImageOwnershipValidation.validDigest(digest) else {
            throw StateStoreError.invalidRecord(
                "Image ownership digest must be a lowercase sha256 OCI digest."
            )
        }
        guard ImageOwnershipValidation.validProviderID(providerID) else {
            throw StateStoreError.invalidRecord(
                "Image ownership provider ID must be one bounded stable identifier."
            )
        }
        self.action = action
        self.reference = reference
        self.digest = digest
        self.providerID = providerID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case action
        case reference
        case digest
        case providerID
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: ImageOwnershipDynamicCodingKey.self)
        let accepted = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = raw.allKeys
            .map(\.stringValue)
            .filter({ !accepted.contains($0) })
            .sorted()
            .first {
            throw StateStoreError.invalidRecord(
                "Image ownership change contains unknown field '\(unknown)'."
            )
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            action: try values.decode(ImageOwnershipChangeAction.self, forKey: .action),
            reference: try values.decode(String.self, forKey: .reference),
            digest: try values.decode(String.self, forKey: .digest),
            providerID: try values.decode(String.self, forKey: .providerID)
        )
    }
}

public struct ImageOwnershipMetadataV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let changes: [ImageOwnershipChangeV1]

    public init(
        version: Int = ImageOwnershipMetadataV1.currentVersion,
        changes: [ImageOwnershipChangeV1]
    ) throws {
        guard version == Self.currentVersion else {
            throw StateStoreError.invalidRecord(
                "Image ownership metadata version \(version) is unsupported."
            )
        }
        guard changes.count <= ImageOwnershipMetadataLimits.maximumChanges else {
            throw StateStoreError.invalidRecord(
                "Image ownership metadata may contain at most \(ImageOwnershipMetadataLimits.maximumChanges) changes."
            )
        }

        let uniqueKeys = Set(changes.map {
            ImageOwnershipChangeKey(
                reference: $0.reference,
                providerID: $0.providerID
            )
        })
        guard uniqueKeys.count == changes.count else {
            throw StateStoreError.invalidRecord(
                "Image ownership metadata contains duplicate changes for one provider/reference."
            )
        }

        self.version = version
        self.changes = changes.sorted(by: Self.changeOrdering)

        guard try canonicalJSONData().count <= ImageOwnershipMetadataLimits.maximumMetadataBytes else {
            throw StateStoreError.invalidRecord(
                "Image ownership metadata exceeds the \(ImageOwnershipMetadataLimits.maximumMetadataBytes)-byte limit."
            )
        }
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func canonicalJSONString() throws -> String {
        let data = try canonicalJSONData()
        guard let value = String(data: data, encoding: .utf8) else {
            throw StateStoreError.invalidRecord(
                "Image ownership metadata could not be encoded as UTF-8."
            )
        }
        return value
    }

    public static func decodeStrict(_ json: String) throws -> ImageOwnershipMetadataV1 {
        guard let data = json.data(using: .utf8),
              data.count <= ImageOwnershipMetadataLimits.maximumMetadataBytes else {
            throw StateStoreError.invalidRecord(
                "Image ownership metadata is not bounded UTF-8 JSON."
            )
        }
        do {
            var duplicateKeyValidator = ImageOwnershipJSONDuplicateKeyValidator(data: data)
            try duplicateKeyValidator.validate()
            return try JSONDecoder().decode(ImageOwnershipMetadataV1.self, from: data)
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError.invalidRecord(
                "Image ownership metadata is malformed: \(error.localizedDescription)"
            )
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case changes
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: ImageOwnershipDynamicCodingKey.self)
        let accepted = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = raw.allKeys
            .map(\.stringValue)
            .filter({ !accepted.contains($0) })
            .sorted()
            .first {
            throw StateStoreError.invalidRecord(
                "Image ownership metadata contains unknown field '\(unknown)'."
            )
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: try values.decode(Int.self, forKey: .version),
            changes: try values.decode([ImageOwnershipChangeV1].self, forKey: .changes)
        )
    }

    private static func changeOrdering(
        _ lhs: ImageOwnershipChangeV1,
        _ rhs: ImageOwnershipChangeV1
    ) -> Bool {
        (lhs.providerID, lhs.reference, lhs.action.rawValue, lhs.digest) <
            (rhs.providerID, rhs.reference, rhs.action.rawValue, rhs.digest)
    }
}

public struct ImageOwnershipRecord: Codable, Equatable, Hashable, Sendable {
    public let reference: String
    public let digest: String
    public let providerID: String
    public let ownershipOperationID: String?
    public let ownershipProofSHA256: String?

    public init(
        reference: String,
        digest: String,
        providerID: String,
        ownershipOperationID: String? = nil,
        ownershipProofSHA256: String? = nil
    ) {
        self.reference = reference
        self.digest = digest
        self.providerID = providerID
        self.ownershipOperationID = ownershipOperationID
        self.ownershipProofSHA256 = ownershipProofSHA256
    }
}

public struct ImageOwnershipProjection: Equatable, Sendable {
    private let recordsByKey: [ImageOwnershipChangeKey: ImageOwnershipRecord]

    fileprivate init(recordsByKey: [ImageOwnershipChangeKey: ImageOwnershipRecord]) {
        self.recordsByKey = recordsByKey
    }

    public static let empty = ImageOwnershipProjection(recordsByKey: [:])

    public var records: [ImageOwnershipRecord] {
        recordsByKey.values.sorted {
            ($0.providerID, $0.reference, $0.digest) <
                ($1.providerID, $1.reference, $1.digest)
        }
    }

    public func record(
        forReference reference: String,
        providerID: String
    ) -> ImageOwnershipRecord? {
        recordsByKey[
            ImageOwnershipChangeKey(reference: reference, providerID: providerID)
        ]
    }

    public func ownsExact(
        reference: String,
        digest: String,
        providerID: String
    ) -> Bool {
        record(forReference: reference, providerID: providerID)?.digest == digest
    }

    public func ownsReference(_ reference: String, providerID: String) -> Bool {
        record(forReference: reference, providerID: providerID) != nil
    }

    public func ownedReferences(
        forDigest digest: String,
        providerID: String
    ) -> [String] {
        records
            .filter { $0.providerID == providerID && $0.digest == digest }
            .map(\.reference)
    }

    public func ownsDigest(_ digest: String, providerID: String) -> Bool {
        !ownedReferences(forDigest: digest, providerID: providerID).isEmpty
    }

    public func everyReferenceIsOwned(
        _ references: [String],
        digest: String,
        providerID: String
    ) -> Bool {
        !references.isEmpty &&
            Set(references).count == references.count &&
            references.allSatisfy {
                ownsExact(reference: $0, digest: digest, providerID: providerID)
            }
    }
}

public struct ImageOwnershipLedger: Sendable {
    public static let groupKind = "image-lifecycle"

    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func load() throws -> ImageOwnershipProjection {
        let matching = try store.operationGroups.loadAll()
            .filter {
                $0.groupKind == Self.groupKind &&
                    $0.status == .succeeded
            }
            .sorted {
                ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id)
            }

        var records: [ImageOwnershipChangeKey: ImageOwnershipRecord] = [:]
        for group in matching {
            guard ImageOwnershipValidation.validOrderingField(group.updatedAt),
                  ImageOwnershipValidation.validOrderingField(group.id) else {
                throw StateStoreError.invalidRecord(
                    "Image ownership group '\(group.id)' has invalid replay ordering fields."
                )
            }
            let metadata: ImageOwnershipMetadataV1
            do {
                metadata = try ImageOwnershipMetadataV1.decodeStrict(
                    group.metadataJSONRedacted
                )
            } catch {
                throw StateStoreError.invalidRecord(
                    "Image ownership group '\(group.id)' has malformed ownership metadata: \(error)"
                )
            }

            for change in metadata.changes {
                let key = ImageOwnershipChangeKey(
                    reference: change.reference,
                    providerID: change.providerID
                )
                switch change.action {
                case .add:
                    records[key] = ImageOwnershipRecord(
                        reference: change.reference,
                        digest: change.digest,
                        providerID: change.providerID,
                        ownershipOperationID: group.id,
                        ownershipProofSHA256: ownershipProof(
                            group: group,
                            change: change
                        )
                    )
                case .remove:
                    if records[key]?.digest == change.digest {
                        records.removeValue(forKey: key)
                    }
                }
            }
        }
        return ImageOwnershipProjection(recordsByKey: records)
    }

    private func ownershipProof(
        group: OperationGroupRecord,
        change: ImageOwnershipChangeV1
    ) -> String {
        let value = [
            group.id,
            group.planHash,
            change.action.rawValue,
            change.providerID,
            change.reference,
            change.digest
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public extension SQLiteStateStore {
    var imageOwnership: ImageOwnershipLedger {
        ImageOwnershipLedger(store: self)
    }
}

private struct ImageOwnershipChangeKey: Hashable, Sendable {
    let reference: String
    let providerID: String
}

private struct ImageOwnershipDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum ImageOwnershipValidation {
    static func validDigest(_ value: String) -> Bool {
        value.range(
            of: "^sha256:[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }

    static func validProviderID(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= ImageOwnershipMetadataLimits.maximumProviderIDBytes &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.range(
                of: "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$",
                options: .regularExpression
            ) != nil
    }

    static func validReference(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= ImageOwnershipMetadataLimits.maximumReferenceBytes,
              !value.hasPrefix("-"),
              !value.contains("://"),
              value.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }),
              !value.contains("//") else {
            return false
        }
        let pathComponent = #"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"#
        let domainLabel = #"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
        let registry = #"\#(domainLabel)(?:\.\#(domainLabel))*(?::[0-9]{1,5})?"#
        let name = #"(?:\#(registry)/)?\#(pathComponent)(?:/\#(pathComponent))*"#
        let tag = #"(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})"#
        let digest = #"sha256:[a-f0-9]{64}"#
        let pattern = #"^\#(name)(?::\#(tag))?(?:@\#(digest))?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            return false
        }
        if let slash = value.firstIndex(of: "/") {
            let registryCandidate = value[..<slash]
            if let colon = registryCandidate.lastIndex(of: ":"),
               registryCandidate[registryCandidate.index(after: colon)...]
                .allSatisfy(\.isNumber),
               (Int(registryCandidate[registryCandidate.index(after: colon)...]) ?? 0) >
                65_535 {
                return false
            }
        }
        return true
    }

    static func validOrderingField(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= 256 &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

private struct ImageOwnershipJSONDuplicateKeyValidator {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw StateStoreError.invalidRecord(
                "Image ownership metadata contains trailing JSON bytes."
            )
        }
    }

    private mutating func parseValue() throws {
        guard index < bytes.count else {
            throw invalidJSON()
        }
        switch bytes[index] {
        case 0x7b:
            try parseObject()
        case 0x5b:
            try parseArray()
        case 0x22:
            _ = try parseString()
        case 0x74:
            try consumeLiteral("true")
        case 0x66:
            try consumeLiteral("false")
        case 0x6e:
            try consumeLiteral("null")
        default:
            try parseNumber()
        }
    }

    private mutating func parseObject() throws {
        index += 1
        skipWhitespace()
        if consume(0x7d) {
            return
        }
        var keys: Set<String> = []
        while true {
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw StateStoreError.invalidRecord(
                    "Image ownership metadata contains duplicate JSON key '\(key)'."
                )
            }
            skipWhitespace()
            guard consume(0x3a) else {
                throw invalidJSON()
            }
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            if consume(0x7d) {
                return
            }
            guard consume(0x2c) else {
                throw invalidJSON()
            }
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws {
        index += 1
        skipWhitespace()
        if consume(0x5d) {
            return
        }
        while true {
            try parseValue()
            skipWhitespace()
            if consume(0x5d) {
                return
            }
            guard consume(0x2c) else {
                throw invalidJSON()
            }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        guard consume(0x22) else {
            throw invalidJSON()
        }
        let start = index - 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
                continue
            }
            if byte == 0x5c {
                escaped = true
                continue
            }
            if byte == 0x22 {
                let literal = Data(bytes[start..<index])
                guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                    throw invalidJSON()
                }
                return value
            }
            if byte < 0x20 {
                throw invalidJSON()
            }
        }
        throw invalidJSON()
    }

    private mutating func parseNumber() throws {
        let start = index
        while index < bytes.count,
              ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[index]) {
            index += 1
        }
        guard index > start else {
            throw invalidJSON()
        }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard bytes[index...].starts(with: expected) else {
            throw invalidJSON()
        }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        index += 1
        return true
    }

    private func invalidJSON() -> StateStoreError {
        .invalidRecord("Image ownership metadata is malformed JSON.")
    }
}

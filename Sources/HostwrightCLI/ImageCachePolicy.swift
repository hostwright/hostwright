import CryptoKit
import Foundation
import HostwrightRuntime

enum ImageCacheLimits {
    static let maximumRecords = 1_024
}

enum ImageCachePressureState: String, Codable, Equatable, Sendable {
    case notConfigured = "not-configured"
    case normal
    case exceeded
}

enum ImageCacheEligibilityReason: String, Codable, Equatable, Sendable {
    case eligible
    case unmanagedReference = "unmanaged-reference"
    case liveReference = "live-reference"
    case leased
    case pinned
    case retained
    case missingOwnership = "missing-ownership"
    case sizeUnavailable = "size-unavailable"
}

struct ImageCacheObservedContent: Equatable, Sendable {
    let providerID: String
    let digest: String
    let sizeBytes: Int64
    let references: [String]
    let ownedReferences: [String]
    let liveReferences: [String]
    let liveDigest: Bool
    let pinned: Bool
    let leased: Bool
    let lastUsedAt: String

    init(
        providerID: String,
        digest: String,
        sizeBytes: Int64,
        references: [String],
        ownedReferences: [String],
        liveReferences: [String] = [],
        liveDigest: Bool = false,
        pinned: Bool = false,
        leased: Bool = false,
        lastUsedAt: String
    ) {
        self.providerID = providerID
        self.digest = digest
        self.sizeBytes = sizeBytes
        self.references = Array(Set(references)).sorted()
        self.ownedReferences = Array(Set(ownedReferences)).sorted()
        self.liveReferences = Array(Set(liveReferences)).sorted()
        self.liveDigest = liveDigest
        self.pinned = pinned
        self.leased = leased
        self.lastUsedAt = lastUsedAt
    }
}

struct ImageCachePrunePolicyV1: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let maximumBytes: Int64?
    let targetBytes: Int64?
    let retentionSeconds: Int
    let maximumDeletions: Int

    init(
        version: Int = currentVersion,
        maximumBytes: Int64?,
        targetBytes: Int64?,
        retentionSeconds: Int,
        maximumDeletions: Int
    ) throws {
        guard version == Self.currentVersion,
              (maximumBytes == nil) == (targetBytes == nil),
              maximumBytes.map({ $0 > 0 }) ?? true,
              targetBytes.map({ $0 >= 0 }) ?? true,
              targetBytes.map({ value in
                  maximumBytes.map { value <= $0 } ?? false
              }) ?? true,
              (0...31_536_000).contains(retentionSeconds),
              (1...256).contains(maximumDeletions) else {
            throw CLIUsageError("Image cache pressure policy is invalid.")
        }
        self.version = version
        self.maximumBytes = maximumBytes
        self.targetBytes = targetBytes
        self.retentionSeconds = retentionSeconds
        self.maximumDeletions = maximumDeletions
    }
}

struct ImageCachePruneCandidateV1: Codable, Equatable, Sendable {
    let providerID: String
    let digest: String
    let sizeBytes: Int64
    let references: [String]
    let lastUsedAt: String
}

struct ImageCacheEligibilityV1: Codable, Equatable, Sendable {
    let providerID: String
    let digest: String
    let sizeBytes: Int64
    let references: [String]
    let ownedReferences: [String]
    let lastUsedAt: String
    let reason: ImageCacheEligibilityReason
}

struct ImageCachePrunePlanV1: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let providerID: String
    let capabilitySHA256: String
    let observationSHA256: String
    let evaluatedAt: String
    let pressure: ImageCachePressureState
    let totalBytes: Int64
    let projectedBytes: Int64
    let policy: ImageCachePrunePolicyV1
    let candidates: [ImageCachePruneCandidateV1]
    let staleOwnedReferences: [String]
    let content: [ImageCacheEligibilityV1]
    let planSHA256: String
}

enum ImageCachePrunePlanner {
    static func plan(
        providerID: String,
        capabilitySHA256: String,
        observationSHA256: String,
        content: [ImageCacheObservedContent],
        staleOwnedReferences: [String],
        policy: ImageCachePrunePolicyV1,
        evaluatedAt: String
    ) throws -> ImageCachePrunePlanV1 {
        guard validIdentifier(providerID),
              validSHA256(capabilitySHA256),
              validSHA256(observationSHA256),
              validTimestamp(evaluatedAt),
              Set(staleOwnedReferences).count == staleOwnedReferences.count,
              staleOwnedReferences.allSatisfy(validReference),
              staleOwnedReferences.count <=
                ImageCacheLimits.maximumRecords,
              content.count <= 10_000 else {
            throw CLIUsageError(
                "Image cache accounting evidence is invalid or exceeds its bound."
            )
        }
        let uniqueKeys = Set(content.map {
            "\($0.providerID)\u{1f}\($0.digest)"
        })
        guard uniqueKeys.count == content.count,
              content.allSatisfy({
                  $0.providerID == providerID &&
                      validSHA256Digest($0.digest) &&
                      $0.sizeBytes >= 0 &&
                      validTimestamp($0.lastUsedAt) &&
                      !$0.references.isEmpty &&
                      Set($0.references).count == $0.references.count &&
                      Set($0.ownedReferences).count ==
                        $0.ownedReferences.count &&
                      Set($0.liveReferences).count ==
                        $0.liveReferences.count
              }) else {
            throw CLIUsageError(
                "Image cache accounting contains malformed or duplicate content."
            )
        }

        let totalBytes = try content.reduce(Int64(0)) { partial, item in
            guard item.sizeBytes <= Int64.max - partial else {
                throw CLIUsageError(
                    "Image cache accounting byte total overflowed."
                )
            }
            return partial + item.sizeBytes
        }
        let pressure: ImageCachePressureState
        if let maximumBytes = policy.maximumBytes {
            pressure = totalBytes > maximumBytes ? .exceeded : .normal
        } else {
            pressure = .notConfigured
        }

        let evaluatedDate = date(from: evaluatedAt)!
        let cutoff = evaluatedDate.addingTimeInterval(
            TimeInterval(-policy.retentionSeconds)
        )
        let eligibility = content.sorted(by: contentOrder).map { item in
            ImageCacheEligibilityV1(
                providerID: item.providerID,
                digest: item.digest,
                sizeBytes: item.sizeBytes,
                references: item.references,
                ownedReferences: item.ownedReferences,
                lastUsedAt: item.lastUsedAt,
                reason: reason(for: item, cutoff: cutoff, pressure: pressure)
            )
        }
        let eligibleByDigest = Dictionary(
            uniqueKeysWithValues: eligibility.map { ($0.digest, $0.reason) }
        )
        let orderedEligible = content
            .filter { eligibleByDigest[$0.digest] == .eligible }
            .sorted {
                let lhsDate = date(from: $0.lastUsedAt)!
                let rhsDate = date(from: $1.lastUsedAt)!
                return lhsDate == rhsDate
                    ? $0.digest < $1.digest
                    : lhsDate < rhsDate
            }

        var projectedBytes = totalBytes
        var candidates: [ImageCachePruneCandidateV1] = []
        if pressure != .normal {
            for item in orderedEligible {
                guard candidates.count < policy.maximumDeletions else {
                    break
                }
                let plannedReferenceCount = candidates.reduce(0) {
                    $0 + $1.references.count
                }
                guard plannedReferenceCount + item.ownedReferences.count <= 256
                else {
                    continue
                }
                if let targetBytes = policy.targetBytes,
                   projectedBytes <= targetBytes {
                    break
                }
                candidates.append(
                    ImageCachePruneCandidateV1(
                        providerID: item.providerID,
                        digest: item.digest,
                        sizeBytes: item.sizeBytes,
                        references: item.ownedReferences,
                        lastUsedAt: item.lastUsedAt
                    )
                )
                projectedBytes = max(0, projectedBytes - item.sizeBytes)
            }
        }
        let plannedReferenceCount = candidates.reduce(0) {
            $0 + $1.references.count
        }
        let remainingReferenceCapacity = max(
            0,
            RuntimeImageLifecycleLimits
                .maximumSourceReferencesPerRequest -
                plannedReferenceCount
        )
        let remainingDeletionCapacity = max(
            0,
            policy.maximumDeletions - candidates.count
        )
        let selectedStaleReferences = Array(
            staleOwnedReferences.sorted().prefix(
                min(
                    remainingReferenceCapacity,
                    remainingDeletionCapacity
                )
            )
        )

        let seed = ImageCachePrunePlanSeed(
            schemaVersion: 1,
            kind: "imageCachePrunePlan",
            providerID: providerID,
            capabilitySHA256: capabilitySHA256,
            observationSHA256: observationSHA256,
            evaluatedAt: evaluatedAt,
            pressure: pressure,
            totalBytes: totalBytes,
            projectedBytes: projectedBytes,
            policy: policy,
            candidates: candidates,
            staleOwnedReferences: selectedStaleReferences,
            content: eligibility
        )
        let digestSeed = ImageCachePrunePlanDigestSeed(
            schemaVersion: seed.schemaVersion,
            kind: seed.kind,
            providerID: seed.providerID,
            capabilitySHA256: seed.capabilitySHA256,
            observationSHA256: seed.observationSHA256,
            pressure: seed.pressure,
            totalBytes: seed.totalBytes,
            projectedBytes: seed.projectedBytes,
            policy: seed.policy,
            candidates: seed.candidates,
            staleOwnedReferences: seed.staleOwnedReferences,
            content: seed.content
        )
        return ImageCachePrunePlanV1(
            schemaVersion: seed.schemaVersion,
            kind: seed.kind,
            providerID: seed.providerID,
            capabilitySHA256: seed.capabilitySHA256,
            observationSHA256: seed.observationSHA256,
            evaluatedAt: seed.evaluatedAt,
            pressure: seed.pressure,
            totalBytes: seed.totalBytes,
            projectedBytes: seed.projectedBytes,
            policy: seed.policy,
            candidates: seed.candidates,
            staleOwnedReferences: seed.staleOwnedReferences,
            content: seed.content,
            planSHA256: sha256(try canonicalData(digestSeed))
        )
    }

    private static func reason(
        for item: ImageCacheObservedContent,
        cutoff: Date,
        pressure: ImageCachePressureState
    ) -> ImageCacheEligibilityReason {
        guard !item.ownedReferences.isEmpty else {
            return .missingOwnership
        }
        guard Set(item.references) == Set(item.ownedReferences) else {
            return .unmanagedReference
        }
        guard !item.liveDigest,
              Set(item.liveReferences).isDisjoint(
                  with: Set(item.references)
              ) else {
            return .liveReference
        }
        guard !item.leased else { return .leased }
        guard !item.pinned else { return .pinned }
        guard let lastUsedAt = date(from: item.lastUsedAt),
              lastUsedAt <= cutoff else {
            return .retained
        }
        guard pressure != .exceeded || item.sizeBytes > 0 else {
            return .sizeUnavailable
        }
        return .eligible
    }

    private static func contentOrder(
        _ lhs: ImageCacheObservedContent,
        _ rhs: ImageCacheObservedContent
    ) -> Bool {
        (lhs.providerID, lhs.digest) < (rhs.providerID, rhs.digest)
    }

    private static func canonicalData<T: Encodable>(
        _ value: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,255})$",
            options: .regularExpression
        ) != nil
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil
    }

    private static func validSHA256Digest(_ value: String) -> Bool {
        value.range(
            of: "^sha256:[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil
    }

    private static func validReference(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 512,
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
               registryCandidate[registryCandidate.index(after: colon)...].allSatisfy(\.isNumber),
               (Int(registryCandidate[registryCandidate.index(after: colon)...]) ?? 0) > 65_535 {
                return false
            }
        }
        return true
    }

    private static func validTimestamp(_ value: String) -> Bool {
        date(from: value) != nil
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

private struct ImageCachePrunePlanSeed: Codable {
    let schemaVersion: Int
    let kind: String
    let providerID: String
    let capabilitySHA256: String
    let observationSHA256: String
    let evaluatedAt: String
    let pressure: ImageCachePressureState
    let totalBytes: Int64
    let projectedBytes: Int64
    let policy: ImageCachePrunePolicyV1
    let candidates: [ImageCachePruneCandidateV1]
    let staleOwnedReferences: [String]
    let content: [ImageCacheEligibilityV1]
}

private struct ImageCachePrunePlanDigestSeed: Codable {
    let schemaVersion: Int
    let kind: String
    let providerID: String
    let capabilitySHA256: String
    let observationSHA256: String
    let pressure: ImageCachePressureState
    let totalBytes: Int64
    let projectedBytes: Int64
    let policy: ImageCachePrunePolicyV1
    let candidates: [ImageCachePruneCandidateV1]
    let staleOwnedReferences: [String]
    let content: [ImageCacheEligibilityV1]
}

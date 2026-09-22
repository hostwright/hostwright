import Foundation
import HostwrightScheduler

struct Phase10SchedulerQualificationStrictJSONScanner {
    private let bytes: [UInt8]
    private let allowedKeys: [String: Set<String>]
    private var index = 0

    init(data: Data, allowedKeys: [String: Set<String>]) {
        bytes = Array(data)
        self.allowedKeys = allowedKeys
    }

    mutating func validate() throws {
        try value(path: "root")
        skipWhitespace()
        guard index == bytes.count else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("trailing JSON") }
    }

    private mutating func value(path: String) throws {
        skipWhitespace()
        guard index < bytes.count else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("truncated JSON") }
        switch bytes[index] {
        case 0x7B: try object(path: path)
        case 0x5B: try array(path: path)
        case 0x22: _ = try string()
        default: try scalar()
        }
    }

    private mutating func object(path: String) throws {
        index += 1
        var seen = Set<String>()
        skipWhitespace()
        if consume(0x7D) { return }
        while true {
            skipWhitespace()
            let key = try string()
            if let allowed = Self.allowedKeys(for: path, in: allowedKeys),
               !allowed.contains("*") && !allowed.contains(key) {
                throw Phase10SchedulerQualificationReceiptError.invalidSchema("unknown JSON key \(key) at \(path)")
            }
            guard seen.insert(key).inserted else {
                throw Phase10SchedulerQualificationReceiptError.invalidSchema("duplicate JSON key \(key) at \(path)")
            }
            skipWhitespace()
            guard consume(0x3A) else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("missing JSON colon") }
            try value(path: Self.childPath(path: path, key: key))
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("missing JSON comma") }
        }
    }

    private mutating func array(path: String) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try value(path: path + "[]")
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("missing JSON array comma") }
        }
    }

    private mutating func scalar() throws {
        let start = index
        while index < bytes.count,
              ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("invalid JSON scalar") }
    }

    private mutating func string() throws -> String {
        guard consume(0x22) else { throw Phase10SchedulerQualificationReceiptError.invalidSchema("expected JSON string") }
        var raw = Data([0x22])
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            raw.append(byte)
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                return try JSONDecoder().decode(String.self, from: raw)
            }
        }
        throw Phase10SchedulerQualificationReceiptError.invalidSchema("unterminated JSON string")
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private static func childPath(path: String, key: String) -> String {
        path == "root" ? "root." + key : path + "." + key
    }

    private static func allowedKeys(
        for path: String,
        in allowedKeys: [String: Set<String>]
    ) -> Set<String>? {
        allowedKeys[path]
    }

    static func validateJSONShape(_ data: Data, canonicalData: Data) throws {
        let actual = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let canonical = try JSONSerialization.jsonObject(
            with: canonicalData,
            options: [.fragmentsAllowed]
        )
        guard sameJSONShape(actual, canonical) else {
            throw Phase10SchedulerQualificationReceiptError.invalidSchema(
                "replay JSON contains an unknown or missing key"
            )
        }
    }

    private static func sameJSONShape(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (left as [String: Any], right as [String: Any]):
            guard left.count == right.count,
                  Set(left.keys) == Set(right.keys) else {
                return false
            }
            return left.allSatisfy { key, value in
                guard let other = right[key] else { return false }
                return sameJSONShape(value, other)
            }
        case let (left as [Any], right as [Any]):
            return left.count == right.count
                && zip(left, right).allSatisfy { sameJSONShape($0, $1) }
        case (_ as NSNull, _ as NSNull):
            return true
        case (_ as String, _ as String),
             (_ as NSNumber, _ as NSNumber):
            return true
        default:
            return false
        }
    }

    static let receiptAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "cell", "testName", "seed", "caseCount", "oracleDomain", "configuration", "directTest", "sourceFingerprint", "inputFingerprint", "buildFingerprint", "executionTranscriptFingerprint", "safetyMismatchCount", "optimizationGapCount", "caseInputFingerprints", "replayFixtures", "outputRootIdentity", "runDirectoryIdentity", "outputRootPathIdentity", "runDirectoryPathIdentity", "cleanupScopeVerified"],
        "root.configuration": ["seed", "generatedCount", "exactCount", "performanceEnabled", "performanceRepeats", "referenceMacGateEnabled", "referenceMacID", "outputRootIdentity"],
        "root.directTest": ["status", "testCount", "failedTestCount", "assertionFailureCount", "skippedTestCount", "elapsedSeconds"],
        "root.replayFixtures[]": ["relativePath", "sha256", "byteCount", "issueKind", "severity", "scenarioSeed", "inputFingerprint", "caseIndex", "oracleDomain"],
        "root.outputRootPathIdentity": ["textualPath", "resolvedPath", "device", "inode"],
        "root.runDirectoryPathIdentity": ["textualPath", "resolvedPath", "device", "inode"]
    ]

    static let performanceAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "hardware", "operatingSystem", "swiftVersion", "seed", "pendingWorkloads", "nodes", "repeats", "samplesSeconds", "p95Seconds", "referenceMacGateEnabled", "referenceMacID", "thresholdEnforced", "sourceFingerprint", "inputFingerprint", "buildFingerprint"]
    ]

    static let performanceTranscriptAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "seed", "pendingWorkloads", "nodes", "repeats", "samplesSeconds", "hardware", "operatingSystem", "swiftVersion", "referenceMacGateEnabled", "referenceMacID", "thresholdEnforced", "sourceFingerprint", "inputFingerprint", "buildFingerprint"]
    ]

    static let performanceManifestAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "recordPath", "recordSha256", "recordByteCount", "transcriptPath", "transcriptSha256", "transcriptByteCount", "outputRootIdentity", "runDirectoryIdentity", "outputRootPathIdentity", "runDirectoryPathIdentity"]
    ]

    static let manifestAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "runDirectoryIdentity", "entries"],
        "root.entries[]": ["relativePath", "sha256", "byteCount", "issueKind", "severity", "scenarioSeed", "inputFingerprint", "caseIndex", "oracleDomain"]
    ]

    static let replayAllowedKeys: [String: Set<String>] = [
        "root": ["schema", "issue", "original", "minimized", "originalIssues", "minimizedIssues", "originalDecision", "minimizedDecision", "oracle"],
        "root.issue": ["kind", "severity", "message"],
        "root.original": ["label", "seed", "input", "oracleMode"],
        "root.minimized": ["label", "seed", "input", "oracleMode"],
        "root.originalIssues[]": ["kind", "severity", "message"],
        "root.minimizedIssues[]": ["kind", "severity", "message"],
        "root.originalDecision": ["decisionID", "inputDigest", "orderedWorkloadIDs", "workloadDecisions", "snapshotQuality"],
        "root.minimizedDecision": ["decisionID", "inputDigest", "orderedWorkloadIDs", "workloadDecisions", "snapshotQuality"],
        "root.oracle": ["inputFingerprint", "domain", "maxPlaced", "canonicalAssignment"]
    ]
}

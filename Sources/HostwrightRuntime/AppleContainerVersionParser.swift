import Foundation

public enum AppleContainerVersionParser {
    public static let maximumBytes = 1_024
    private static let versionPattern = #"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"#
    private static let buildPattern = #"(debug|release)"#
    private static let commitPattern = #"([0-9a-f]{7}|unspecified)"#

    public static func parseCLIIdentity(_ output: String) -> AppleContainerCLIIdentity? {
        guard !output.isEmpty, output.utf8.count <= maximumBytes else {
            return nil
        }
        let pattern = #"\Acontainer CLI version ("# + versionPattern
            + #") \(build: "# + buildPattern
            + #", commit: "# + commitPattern + #"\)\n?\z"#
        guard let captures = captures(in: output, pattern: pattern, count: 3) else {
            return nil
        }
        return AppleContainerCLIIdentity(
            version: captures[0],
            build: captures[1],
            commit: captures[2]
        )
    }

    public static func parse(_ output: String) -> String? {
        if let identity = parseCLIIdentity(output) {
            return identity.version
        }
        if let identity = parseServiceIdentity(output) {
            return identity.version
        }
        guard !output.isEmpty, output.utf8.count <= maximumBytes else {
            return nil
        }
        let legacyCLIPattern = #"\Acontainer CLI version ("#
            + versionPattern + #")\n?\z"#
        if let version = captures(
            in: output,
            pattern: legacyCLIPattern,
            count: 1
        )?.first {
            return version
        }
        let legacyServicePattern = #"\Acontainer-apiserver version ("#
            + versionPattern + #")\n?\z"#
        return captures(in: output, pattern: legacyServicePattern, count: 1)?.first
    }

    public static func parseServiceIdentity(_ output: String) -> AppleContainerCLIIdentity? {
        guard !output.isEmpty, output.utf8.count <= maximumBytes else {
            return nil
        }
        let pattern = #"\Acontainer-apiserver version ("# + versionPattern
            + #") \(build: "# + buildPattern
            + #", commit: "# + commitPattern + #"\)\n?\z"#
        guard let captures = captures(in: output, pattern: pattern, count: 3) else {
            return nil
        }
        return AppleContainerCLIIdentity(
            version: captures[0],
            build: captures[1],
            commit: captures[2]
        )
    }

    public static func isValidExpectedVersion(_ value: String) -> Bool {
        value.range(of: "\\A" + versionPattern + "\\z", options: .regularExpression) != nil
    }

    private static func captures(
        in output: String,
        pattern: String,
        count: Int
    ) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ) else {
            return nil
        }
        var values: [String] = []
        for captureIndex in 1...count {
            let capture = match.range(at: captureIndex)
            guard capture.location != NSNotFound,
                  let range = Range(capture, in: output) else {
                continue
            }
            values.append(String(output[range]))
        }
        return values
    }
}

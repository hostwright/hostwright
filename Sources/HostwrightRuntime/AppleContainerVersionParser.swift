import Foundation

public enum AppleContainerVersionParser {
    private static let versionPattern = #"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?"#

    public static func parse(_ output: String) -> String? {
        let pattern = #"\bversion\s+("# + versionPattern + ")"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[range])
    }

    public static func isValidExpectedVersion(_ value: String) -> Bool {
        value.range(of: "^" + versionPattern + "$", options: .regularExpression) != nil
    }
}

import Foundation
import HostwrightCore

public enum ImageReferencePolicy {
    public static func validate(
        _ image: String,
        serviceName: String,
        policy: HostwrightImagePolicy
    ) -> [ManifestIssue] {
        var issues: [ManifestIssue] = []

        if image.contains("://") {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' image must be an OCI-style image reference, not a URL."
                )
            )
        }

        let digestStatus = digestPinStatus(image)
        switch digestStatus {
        case .valid:
            break
        case .absent:
            if policy == .requireDigest {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' imagePolicy require-digest requires image '\(image)' to be digest-pinned with @sha256:<64 lowercase hex characters>; mutable tags are not accepted as content identity."
                    )
                )
            }
        case .invalid:
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' image digest must use @sha256:<64 lowercase hex characters>."
                )
            )
        }

        return issues
    }

    public static func isDigestPinned(_ image: String) -> Bool {
        digestPinStatus(image) == .valid
    }

    private enum DigestPinStatus {
        case absent
        case invalid
        case valid
    }

    private static func digestPinStatus(_ image: String) -> DigestPinStatus {
        let parts = image.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count != 1 else { return .absent }
        guard parts.count == 2, let name = parts.first, !name.isEmpty, let digest = parts.last else {
            return .invalid
        }

        let digestString = String(digest)
        let pattern = #"^sha256:[a-f0-9]{64}$"#
        return digestString.range(of: pattern, options: .regularExpression) == nil ? .invalid : .valid
    }
}

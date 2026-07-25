import Foundation

public struct ImageTrustExceptionApproval: Equatable, Sendable {
    public static let currentAPIVersion = 1
    public static let maximumBytes = 16 * 1_024

    public let apiVersion: Int
    public let projectID: String
    public let serviceName: String
    public let descriptorDigest: String
    public let reason: String
    public let approver: String
    public let approvedAt: String
    public let expiresAt: String
    public let idempotencyKey: String

    public static func parse(_ data: Data) throws -> ImageTrustExceptionApproval {
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes: Self.maximumBytes,
                allowedKeys: [
                    "apiVersion", "projectID", "serviceName",
                    "descriptorDigest", "reason", "approver",
                    "approvedAt", "expiresAt", "idempotencyKey"
                ],
                requiredKeys: [
                    "apiVersion", "projectID", "serviceName",
                    "descriptorDigest", "reason", "approver",
                    "approvedAt", "expiresAt", "idempotencyKey"
                ]
            )
        } catch {
            throw ImageTrustVerifierError.invalidPolicy
        }
        guard RegistryStrictJSONObject.integer(object["apiVersion"]) ==
                currentAPIVersion,
              let projectID = bounded(
                  object["projectID"],
                  maximumBytes: 256
              ),
              projectID.hasPrefix("project-"),
              let serviceName = bounded(
                  object["serviceName"],
                  maximumBytes: 128
              ),
              let descriptorDigest = object["descriptorDigest"] as? String,
              (try? OCIContentDigest(descriptorDigest))?.algorithm ==
                "sha256",
              let reason = bounded(
                  object["reason"],
                  maximumBytes: 512
              ),
              let approver = bounded(
                  object["approver"],
                  maximumBytes: 256
              ),
              let approvedAt = object["approvedAt"] as? String,
              let expiresAt = object["expiresAt"] as? String,
              let approvedDate = timestamp(approvedAt),
              let expiryDate = timestamp(expiresAt),
              expiryDate > approvedDate,
              let idempotencyKey = object["idempotencyKey"] as? String,
              UUID(uuidString: idempotencyKey) != nil,
              idempotencyKey.utf8.count == 36 else {
            throw ImageTrustVerifierError.invalidPolicy
        }
        return ImageTrustExceptionApproval(
            apiVersion: currentAPIVersion,
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: descriptorDigest,
            reason: reason,
            approver: approver,
            approvedAt: approvedAt,
            expiresAt: expiresAt,
            idempotencyKey: idempotencyKey.lowercased()
        )
    }

    private static func bounded(
        _ raw: Any?,
        maximumBytes: Int
    ) -> String? {
        guard let value = raw as? String,
              !value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func timestamp(_ value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        let base = ISO8601DateFormatter()
        base.formatOptions = [.withInternetDateTime]
        if let date = base.date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds
        ]
        return fractional.date(from: value)
    }
}

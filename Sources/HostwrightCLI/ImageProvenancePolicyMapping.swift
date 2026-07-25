import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRegistry

struct ImageProvenancePolicyContext: Equatable, Sendable {
    let policy: ImageProvenancePolicy
    let material: ImageProvenancePolicyMaterial
}

enum ImageProvenancePolicyMapping {
    static func map(
        _ manifest: HostwrightManifest
    ) throws -> ImageProvenancePolicyContext {
        guard let source = manifest.imageProvenance else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "The manifest does not declare imageProvenance. No provenance evidence was changed."
            )
        }
        do {
            let policy = try ImageProvenancePolicy(
                version: source.version,
                requirement: source.requirement == .required
                    ? .required : .optional,
                builderIDs: source.builderIDs,
                buildTypes: source.buildTypes,
                signers: try source.signers.map { signer in
                    try ImageProvenanceSigner(
                        id: signer.id,
                        publicKeyPath: signer.publicKey,
                        notBefore: try signer.notBefore.map(
                            parseTimestamp
                        ),
                        notAfter: try signer.notAfter.map(
                            parseTimestamp
                        ),
                        revokedAt: try signer.revokedAt.map(
                            parseTimestamp
                        )
                    )
                },
                maximumAgeSeconds: source.maximumAgeSeconds,
                requireReproducible:
                    source.requireReproducible
            )
            return ImageProvenancePolicyContext(
                policy: policy,
                material:
                    try ImageProvenancePolicyMaterial.resolve(
                        policy
                    )
            )
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "The imageProvenance policy or signer material is invalid or unsafe."
            )
        }
    }

    static func selectService(
        _ requested: String?,
        manifest: HostwrightManifest
    ) throws -> String {
        if let requested {
            guard manifest.services.contains(where: {
                $0.name == requested
            }) else {
                throw HostwrightDiagnostic(
                    code: .commandUsage,
                    message: "Manifest does not declare service '\(requested)'. No provenance evidence was changed."
                )
            }
            return requested
        }
        guard manifest.services.count == 1,
              let service = manifest.services.first else {
            throw HostwrightDiagnostic(
                code: .commandUsage,
                message: "Image provenance operations require --service when the manifest declares more than one service."
            )
        }
        return service.name
    }

    private static func parseTimestamp(
        _ value: String
    ) throws -> Date {
        let exact = ISO8601DateFormatter()
        exact.formatOptions = [.withInternetDateTime]
        if let date = exact.date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds
        ]
        guard let date = fractional.date(from: value) else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "imageProvenance contains an invalid RFC3339 timestamp."
            )
        }
        return date
    }
}

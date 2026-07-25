import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRegistry

enum ImageTrustPolicyMapping {
    static func map(
        _ manifest: HostwrightManifest
    ) throws -> (
        policy: ImageTrustVerificationPolicy,
        material: ImageTrustPolicyMaterial
    ) {
        guard let source = manifest.imageTrust else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "The manifest does not declare imageTrust. No trust evidence was changed."
            )
        }
        do {
            let authorities = try source.authorities.map { authority in
                try ImageTrustAuthority(
                    id: authority.id,
                    kind: authority.type == .keyed ? .keyed : .keyless,
                    publicKeyPath: authority.publicKey,
                    issuer: authority.issuer,
                    identity: authority.identity,
                    notBefore: try authority.notBefore.map(parseTimestamp),
                    notAfter: try authority.notAfter.map(parseTimestamp),
                    revokedAt: try authority.revokedAt.map(parseTimestamp)
                )
            }
            let policy = try ImageTrustVerificationPolicy(
                version: source.version,
                threshold: source.threshold,
                trustedRootPath: source.trustedRoot,
                authorities: authorities
            )
            return (
                policy,
                try ImageTrustPolicyMaterial.resolve(policy)
            )
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "The imageTrust policy or its trust material is invalid or unsafe."
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
                    message: "Manifest does not declare service '\(requested)'. No trust evidence was changed."
                )
            }
            return requested
        }
        guard manifest.services.count == 1,
              let service = manifest.services.first else {
            throw HostwrightDiagnostic(
                code: .commandUsage,
                message: "Image trust verification requires --service when the manifest declares more than one service."
            )
        }
        return service.name
    }

    private static func parseTimestamp(_ value: String) throws -> Date {
        let base = ISO8601DateFormatter()
        base.formatOptions = [.withInternetDateTime]
        if let date = base.date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds
        ]
        guard let date = fractional.date(from: value) else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "imageTrust contains an invalid RFC3339 timestamp."
            )
        }
        return date
    }
}

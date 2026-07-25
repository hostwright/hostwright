import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRegistry

struct ImageSBOMPolicyMaterial: Equatable, Sendable {
    let requirement: HostwrightImageSBOMRequirement
    let formats: Set<ImageSBOMFormat>
    let policySHA256: String
}

enum ImageSBOMPolicyMapping {
    static func map(
        _ manifest: HostwrightManifest
    ) throws -> ImageSBOMPolicyMaterial {
        guard let source = manifest.imageSBOM else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "The manifest does not declare imageSBOM. No SBOM evidence was changed."
            )
        }
        let formats = try Set(source.formats.map { value in
            guard let format = ImageSBOMFormat(
                rawValue: value.rawValue
            ) else {
                throw HostwrightDiagnostic(
                    code: .manifestValidationFailed,
                    message: "The imageSBOM format is unsupported."
                )
            }
            return format
        })
        let canonical: [String: Any] = [
            "version": source.version,
            "requirement": source.requirement.rawValue,
            "formats": formats.map(\.rawValue).sorted()
        ]
        let data = try JSONSerialization.data(
            withJSONObject: canonical,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return ImageSBOMPolicyMaterial(
            requirement: source.requirement,
            formats: formats,
            policySHA256: SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    static func selectService(
        _ requested: String?,
        manifest: HostwrightManifest
    ) throws -> String {
        if let requested {
            guard manifest.services.contains(
                where: { $0.name == requested }
            ) else {
                throw HostwrightDiagnostic(
                    code: .commandUsage,
                    message: "Manifest does not declare the requested SBOM service."
                )
            }
            return requested
        }
        guard manifest.services.count == 1,
              let service = manifest.services.first else {
            throw HostwrightDiagnostic(
                code: .commandUsage,
                message: "Image SBOM operations require --service when the manifest declares more than one service."
            )
        }
        return service.name
    }
}

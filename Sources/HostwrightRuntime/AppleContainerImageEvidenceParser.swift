import Foundation

public enum AppleContainerImageEvidenceParser {
    public static let maximumBytes = AppleContainerImageListOutputParser.maximumBytes

    public static func parse(
        _ text: String,
        expectedReference: String,
        preferredArchitecture: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> RuntimeLocalImageEvidence {
        do {
            let data = try AppleContainerStructuredOutput.validatedJSONData(
                text,
                operation: "Apple container image evidence",
                maximumBytes: maximumBytes
            )
            let images = try JSONDecoder().decode([ImagePayload].self, from: data)
            let matches = images.filter { $0.configuration.name == expectedReference }
            guard matches.count == 1, let image = matches.first else {
                throw RuntimeAdapterError.capabilityUnavailable(.lifecycleMutation)
            }
            guard digestIsValid(image.configuration.descriptor.digest) else {
                throw RuntimeAdapterError.outputParseFailed("Local image descriptor digest is missing or invalid.")
            }
            let preferredVariants = image.variants.filter {
                $0.platform.architecture == preferredArchitecture
            }
            let variant: Variant
            if preferredVariants.count == 1, let preferred = preferredVariants.first {
                variant = preferred
            } else if preferredVariants.isEmpty,
                      image.variants.count == 1,
                      let onlyVariant = image.variants.first {
                variant = onlyVariant
            } else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Local image platform evidence was missing or ambiguous."
                )
            }
            guard
                  digestIsValid(variant.digest),
                  !variant.platform.architecture.isEmpty,
                  !variant.platform.os.isEmpty else {
                throw RuntimeAdapterError.outputParseFailed("Local image platform evidence is missing or invalid.")
            }
            return RuntimeLocalImageEvidence(
                reference: expectedReference,
                descriptorDigest: image.configuration.descriptor.digest,
                variantDigest: variant.digest,
                architecture: variant.platform.architecture,
                operatingSystem: variant.platform.os
            )
        } catch let error as RuntimeAdapterError {
            throw error
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                redactionPolicy.redact("Could not parse local Apple container image evidence: \(error)")
            )
        }
    }

    private static func digestIsValid(_ value: String) -> Bool {
        value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private struct ImagePayload: Decodable {
        let configuration: Configuration
        let variants: [Variant]
    }

    private struct Configuration: Decodable {
        let descriptor: Descriptor
        let name: String
    }

    private struct Descriptor: Decodable {
        let digest: String
    }

    private struct Variant: Decodable {
        let digest: String
        let platform: Platform
    }

    private struct Platform: Decodable {
        let architecture: String
        let os: String
    }
}

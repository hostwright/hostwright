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
            let expectedDescriptorDigest = try expectedDescriptorDigest(
                in: expectedReference
            )
            let matches = images.filter {
                matchesExpectedReference(
                    $0.configuration,
                    expectedReference: expectedReference,
                    expectedDescriptorDigest: expectedDescriptorDigest
                )
            }
            guard !matches.isEmpty else {
                throw RuntimeAdapterError.capabilityUnavailable(.lifecycleMutation)
            }
            let normalizedMatches = try matches.map(normalizedEvidence)
            guard let image = normalizedMatches.first,
                  normalizedMatches.dropFirst().allSatisfy({ $0 == image }),
                  expectedDescriptorDigest.map({ $0 == image.descriptorDigest }) ?? true else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Local image aliases contained conflicting descriptor or variant evidence."
                )
            }
            let preferredVariants = image.variants.filter {
                $0.architecture == preferredArchitecture
            }
            let variant: NormalizedVariant
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
            return RuntimeLocalImageEvidence(
                reference: expectedReference,
                descriptorDigest: image.descriptorDigest,
                variantDigest: variant.digest,
                architecture: variant.architecture,
                operatingSystem: variant.operatingSystem
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

    private static func expectedDescriptorDigest(
        in expectedReference: String
    ) throws -> String? {
        let parts = expectedReference.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else {
            return nil
        }
        guard !parts[0].isEmpty,
              digestIsValid(String(parts[1])) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Expected local image digest reference is invalid."
            )
        }
        return String(parts[1])
    }

    private static func matchesExpectedReference(
        _ configuration: Configuration,
        expectedReference: String,
        expectedDescriptorDigest: String?
    ) -> Bool {
        if configuration.name == expectedReference {
            return true
        }
        guard let expectedDescriptorDigest,
              configuration.descriptor.digest == expectedDescriptorDigest,
              repository(of: configuration.name) == repository(of: expectedReference) else {
            return false
        }
        return true
    }

    private static func normalizedEvidence(
        _ image: ImagePayload
    ) throws -> NormalizedImageEvidence {
        let descriptorDigest = image.configuration.descriptor.digest
        guard digestIsValid(descriptorDigest) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Local image descriptor digest is missing or invalid."
            )
        }
        let variants = try image.variants.map { variant in
            guard digestIsValid(variant.digest),
                  !variant.platform.architecture.isEmpty,
                  !variant.platform.os.isEmpty else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Local image platform evidence is missing or invalid."
                )
            }
            return NormalizedVariant(
                digest: variant.digest,
                architecture: variant.platform.architecture,
                operatingSystem: variant.platform.os
            )
        }.sorted {
            ($0.architecture, $0.operatingSystem, $0.digest) <
                ($1.architecture, $1.operatingSystem, $1.digest)
        }
        return NormalizedImageEvidence(
            descriptorDigest: descriptorDigest,
            variants: variants
        )
    }

    private static func repository(of reference: String) -> String {
        let withoutDigest = reference.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? reference
        guard let colon = withoutDigest.lastIndex(of: ":") else {
            return withoutDigest
        }
        let slash = withoutDigest.lastIndex(of: "/")
        guard slash == nil || colon > slash! else {
            return withoutDigest
        }
        return String(withoutDigest[..<colon])
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

    private struct NormalizedImageEvidence: Equatable {
        let descriptorDigest: String
        let variants: [NormalizedVariant]
    }

    private struct NormalizedVariant: Equatable {
        let digest: String
        let architecture: String
        let operatingSystem: String
    }
}

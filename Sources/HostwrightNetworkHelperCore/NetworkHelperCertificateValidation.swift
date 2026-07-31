import Foundation
import HostwrightNetworking

enum NetworkHelperCertificateValidation {
  static func validated(
    _ bindings: [ProjectCertificateRequestBinding]
  ) throws -> [ProjectCertificateRequestBinding] {
    guard bindings.count <= HostwrightCertificateDeclaration.maximumCertificates else {
      throw NetworkHelperError.invalidCertificate
    }
    var names = Set<String>()
    var identifiers = Set<String>()
    var result: [ProjectCertificateRequestBinding] = []
    for binding in bindings {
      guard HostwrightNetworkIdentity.isValidManifestName(binding.name),
        canonicalUUID(binding.certificateUUID),
        names.insert(binding.name).inserted,
        identifiers.insert(binding.certificateUUID).inserted,
        !binding.dnsNames.isEmpty,
        binding.dnsNames.count <= HostwrightIngressListener.maximumRoutes,
        Set(binding.dnsNames).count == binding.dnsNames.count,
        binding.dnsNames.allSatisfy(validLowercaseHostname),
        binding.peerIdentities.count <= HostwrightIngressListener.maximumPeers,
        Set(binding.peerIdentities).count == binding.peerIdentities.count,
        binding.peerIdentities.allSatisfy({
          $0.isExactCanonicalValue()
        }),
        (3_600...2_592_000).contains(binding.renewBeforeSeconds),
        (86_400...31_536_000).contains(binding.validitySeconds),
        binding.renewBeforeSeconds < binding.validitySeconds
      else {
        throw NetworkHelperError.invalidCertificate
      }
      switch binding.source {
      case .imported:
        guard validSHA256(binding.identitySHA256), binding.issuer == nil else {
          throw NetworkHelperError.invalidCertificate
        }
      case .localCA:
        guard binding.identitySHA256 == nil, binding.issuer == nil else {
          throw NetworkHelperError.invalidCertificate
        }
      case .provider:
        guard binding.identitySHA256 == nil,
          let issuer = binding.issuer,
          HostwrightNetworkIdentity.isValidManifestName(issuer)
        else {
          throw NetworkHelperError.invalidCertificate
        }
      }
      result.append(
        ProjectCertificateRequestBinding(
          name: binding.name,
          certificateUUID: binding.certificateUUID,
          source: binding.source,
          identitySHA256: binding.identitySHA256,
          issuer: binding.issuer,
          renewBeforeSeconds: binding.renewBeforeSeconds,
          validitySeconds: binding.validitySeconds,
          statusPolicy: binding.statusPolicy,
          dnsNames: binding.dnsNames.sorted(),
          identityRole: binding.identityRole,
          peerIdentities: binding.peerIdentities
        )
      )
    }
    return result.sorted(by: ProjectCertificateRequestBinding.canonicalPrecedes)
  }

  private static func canonicalUUID(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString.lowercased() == value
  }

  private static func validSHA256(_ value: String?) -> Bool {
    guard let value else { return false }
    return value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
  }

  private static func validLowercaseHostname(_ value: String) -> Bool {
    value == value.lowercased() && HostwrightHostAccessPolicy.isValidHostname(value)
  }
}

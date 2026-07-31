import Darwin
import Foundation
import HostwrightNetworking

enum NetworkHelperIngressValidation {
  static let maximumBackendsPerRoute = 256

  static func validated(
    _ listeners: [ProjectIngressListenerBinding]
  ) throws -> [ProjectIngressListenerBinding] {
    guard listeners.count <= HostwrightIngressListener.maximumListeners else {
      throw NetworkHelperError.invalidRequest
    }
    var names = Set<String>()
    var endpoints = Set<String>()
    var canonicalListeners: [ProjectIngressListenerBinding] = []
    for listener in listeners {
      guard
        HostwrightNetworkIdentity.isValidManifestName(
          listener.name
        ),
        names.insert(listener.name).inserted,
        NetworkExposurePolicyValidation.isSemanticallyValid(
          listener.exposure,
          bindAddress: listener.bindAddress
        ),
        directListenerExposure(listener.exposure),
        (1...65_535).contains(listener.port),
        !listener.routes.isEmpty,
        listener.routes.count <= HostwrightIngressListener.maximumRoutes,
        endpoints.insert(
          "\(listener.bindAddress):\(listener.port)"
        ).inserted
      else {
        throw NetworkHelperError.invalidRequest
      }
      if let certificate = listener.certificate {
        guard
          HostwrightNetworkIdentity.isValidManifestName(
            certificate
          )
        else {
          throw NetworkHelperError.invalidCertificate
        }
      }
      let peerIdentities = listener.peerIdentities.sorted {
        $0.uriSAN < $1.uriSAN
      }
      guard
        peerIdentities.count <= HostwrightIngressListener.maximumPeers,
        Set(peerIdentities).count == peerIdentities.count,
        peerIdentities.allSatisfy({
          $0.isExactCanonicalValue()
        })
      else {
        throw NetworkHelperError.invalidCertificate
      }
      if listener.exposure.authentication == .mutualTLS {
        guard listener.certificate != nil,
          !peerIdentities.isEmpty
        else {
          throw NetworkHelperError.invalidCertificate
        }
      } else {
        guard peerIdentities.isEmpty else {
          throw NetworkHelperError.invalidCertificate
        }
        if listener.exposure.authentication == .tls,
          listener.certificate == nil
        {
          throw NetworkHelperError.invalidCertificate
        }
      }
      var routeKeys = Set<String>()
      var canonicalRoutes: [ProjectIngressRouteBinding] = []
      for route in listener.routes {
        guard
          HostwrightHostAccessPolicy.isValidHostname(
            route.hostname
          ),
          validPathPrefix(route.pathPrefix),
          !route.methods.isEmpty,
          route.methods.count <= HostwrightIngressRoute.maximumMethods,
          Set(route.methods).count == route.methods.count,
          !route.targetServiceUUIDs.isEmpty,
          route.targetServiceUUIDs.count <= maximumBackendsPerRoute,
          route.targetServiceUUIDs.allSatisfy(
            canonicalUUID
          ),
          Set(route.targetServiceUUIDs).count == route.targetServiceUUIDs.count,
          (1...65_535).contains(route.targetPort),
          route.backends.count <= maximumBackendsPerRoute
        else {
          throw NetworkHelperError.invalidRequest
        }
        let allowedMethods: Set<String> = [
          "DELETE", "GET", "HEAD", "OPTIONS",
          "PATCH", "POST", "PUT",
        ]
        guard Set(route.methods).isSubset(of: allowedMethods),
          route.protocolName != .websocket || route.methods == ["GET"]
        else {
          throw NetworkHelperError.invalidRequest
        }
        for method in route.methods {
          guard
            routeKeys.insert(
              [
                route.hostname,
                route.pathPrefix,
                route.protocolName.rawValue,
                method,
              ].joined(separator: "\u{1f}")
            ).inserted
          else {
            throw NetworkHelperError.invalidRequest
          }
        }
        let targets = Set(route.targetServiceUUIDs)
        guard
          route.backends.allSatisfy({
            targets.contains($0.serviceUUID) && canonicalUUID($0.serviceUUID)
              && canonicalAddress($0.address) && $0.port == route.targetPort
          }),
          Set(route.backends).count == route.backends.count
        else {
          throw NetworkHelperError.invalidRequest
        }
        canonicalRoutes.append(
          ProjectIngressRouteBinding(
            hostname: route.hostname,
            pathPrefix: route.pathPrefix,
            methods: route.methods,
            protocolName: route.protocolName,
            targetServiceName: route.targetServiceName,
            targetServiceUUIDs:
              route.targetServiceUUIDs,
            targetPort: route.targetPort,
            backends: route.backends
          )
        )
      }
      canonicalListeners.append(
        ProjectIngressListenerBinding(
          name: listener.name,
          bindAddress: listener.bindAddress,
          port: listener.port,
          exposure: listener.exposure,
          certificate: listener.certificate,
          peerIdentities: peerIdentities,
          routes: canonicalRoutes
        )
      )
    }
    return canonicalListeners.sorted(
      by: ProjectIngressListenerBinding.canonicalPrecedes
    )
  }

  private static func canonicalUUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
  }

  private static func directListenerExposure(
    _ exposure: HostwrightPortExposurePolicy
  ) -> Bool {
    switch exposure.scope {
    case .localhost, .lan:
      return true
    case .public:
      return exposure.authentication == .mutualTLS
    case .project, .tunnel:
      return false
    }
  }

  private static func canonicalAddress(_ value: String) -> Bool {
    var ipv4 = in_addr()
    if value.withCString({
      inet_pton(AF_INET, $0, &ipv4)
    }) == 1 {
      return renderIPv4(&ipv4) == value
    }
    var ipv6 = in6_addr()
    guard
      value.withCString({
        inet_pton(AF_INET6, $0, &ipv6)
      }) == 1
    else {
      return false
    }
    return renderIPv6(&ipv6) == value
  }

  private static func renderIPv4(_ value: inout in_addr) -> String? {
    var buffer = [CChar](
      repeating: 0,
      count: Int(INET_ADDRSTRLEN)
    )
    guard
      inet_ntop(
        AF_INET,
        &value,
        &buffer,
        socklen_t(buffer.count)
      ) != nil
    else {
      return nil
    }
    return buffer.withUnsafeBufferPointer {
      String(
        decoding:
          $0
          .prefix { $0 != 0 }
          .map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
    }
  }

  private static func renderIPv6(_ value: inout in6_addr) -> String? {
    var buffer = [CChar](
      repeating: 0,
      count: Int(INET6_ADDRSTRLEN)
    )
    guard
      inet_ntop(
        AF_INET6,
        &value,
        &buffer,
        socklen_t(buffer.count)
      ) != nil
    else {
      return nil
    }
    return buffer.withUnsafeBufferPointer {
      String(
        decoding:
          $0
          .prefix { $0 != 0 }
          .map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
    }
  }

  private static func validPathPrefix(_ value: String) -> Bool {
    if value == "/" { return true }
    guard value.hasPrefix("/"),
      value.utf8.count <= 1_024,
      value.rangeOfCharacter(
        from: .controlCharacters
      ) == nil,
      !value.contains("%"),
      !value.contains("?"),
      !value.contains("#"),
      !value.contains("//")
    else {
      return false
    }
    return value.split(
      separator: "/",
      omittingEmptySubsequences: false
    ).dropFirst().allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }
}

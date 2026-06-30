import HostwrightNetworking

let hostwrightNetworkingSmoke: Void = {
    let tunnelBinding = PortBinding(target: 443, published: 443, protocolName: .tcp, scope: .tunnel)
    precondition(tunnelBinding.validate().count == 1)
    precondition(!NetworkExposureScope.tunnel.isAllowedInFirstRelease)

    let localhostBinding = PortBinding(target: 80, published: 8080, protocolName: .tcp, scope: .localhost)
    precondition(localhostBinding.validate().isEmpty)
}()


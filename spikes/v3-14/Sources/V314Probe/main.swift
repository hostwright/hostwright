import Foundation

func log(_ message: String, destination: FileHandle = .standardOutput) {
    destination.write(Data((message + "\n").utf8))
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "exporter" where arguments.count == 1:
        try ExporterProbe.run()
    case "listen" where arguments.count == 3:
        let (host, port) = try VMProbe.endpoint(arguments[1], arguments[2])
        try VMProbe.listen(host, port)
    case "dial" where arguments.count == 3 || (arguments.count == 4 && arguments[3] == "--once"):
        let (host, port) = try VMProbe.endpoint(arguments[1], arguments[2])
        try VMProbe.dial(host, port, once: arguments.count == 4)
    case "quic-listen" where arguments.count == 4:
        let (host, port) = try VMProbe.endpoint(arguments[1], arguments[2])
        let certificate = URL(fileURLWithPath: arguments[3])
        try VMQUICProbe.listen(host, port, certificate: certificate)
    case "quic-dial" where arguments.count == 4 || (arguments.count == 5 && arguments[4] == "--once"):
        let (host, port) = try VMProbe.endpoint(arguments[1], arguments[2])
        let pin = try VMQUICProbe.readCertificate(URL(fileURLWithPath: arguments[3]))
        try VMProbe.dial(host, port, transport: .quic(pin), once: arguments.count == 5)
    default:
        throw ProbeFailure("""
            Usage: v314-probe exporter
                   v314-probe listen <ipv4> <port>
                   v314-probe dial <ipv4> <port> [--once]
                   v314-probe quic-listen <ipv4> <port> <new-public-certificate.der>
                   v314-probe quic-dial <ipv4> <port> <public-certificate.der> [--once]
            """)
    }
} catch {
    log(String(describing: error), destination: .standardError)
    exit(1)
}

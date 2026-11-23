import Foundation

func log(_ message: String, destination: FileHandle = .standardOutput) {
    destination.write(Data((message + "\n").utf8))
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["exporter"] {
        try ExporterProbe.run()
    } else if arguments.count == 3 || (arguments.count == 4 && arguments[0] == "dial" && arguments[3] == "--once") {
        let (host, port) = try VMProbe.endpoint(arguments[1], arguments[2])
        switch arguments[0] {
        case "listen": try VMProbe.listen(host, port)
        case "dial": try VMProbe.dial(host, port, once: arguments.count == 4)
        default: throw ProbeFailure("Expected listen or dial")
        }
    } else {
        throw ProbeFailure("Usage: v314-probe exporter | listen <ipv4> <port> | dial <ipv4> <port> [--once]")
    }
} catch {
    log(String(describing: error), destination: .standardError)
    exit(1)
}

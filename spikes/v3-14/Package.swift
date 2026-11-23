// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "V314LocalNetworkSpike",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "v314-probe", targets: ["V314Probe"])],
    targets: [.executableTarget(name: "V314Probe")]
)

// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "V391LinkTransport",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "v391-link-transport", targets: ["V391"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", exact: "1.45.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
    ],
    targets: [
        .executableTarget(
            name: "V391",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ]
        ),
    ]
)

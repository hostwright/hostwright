import XCTest
@testable import HostwrightManifest

final class Phase07NetworkManifestTests: XCTestCase {
    func testNetworkDeclarationsAndAttachmentsRoundTripCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 2
            project: network-demo
            networks:
              frontend: {}
              backend:
                driver: hostOnly
                ipv4: 10.42.0.0/24
                ipv6: fd42::/64
            services:
              api:
                image: local/api:latest
                networks:
                  - network: backend
                    aliases: [z-api, api]
                  - frontend
            """
        )

        XCTAssertEqual(manifest.networks.keys.sorted(), ["backend", "frontend"])
        XCTAssertEqual(manifest.networks["frontend"]?.driver.rawValue, "nat")
        XCTAssertEqual(manifest.networks["frontend"]?.ipv4.manifestValue, "auto")
        XCTAssertEqual(manifest.networks["frontend"]?.ipv6.manifestValue, "auto")
        XCTAssertEqual(manifest.networks["backend"]?.driver.rawValue, "hostOnly")
        XCTAssertEqual(manifest.networks["backend"]?.ipv4.manifestValue, "10.42.0.0/24")
        XCTAssertEqual(manifest.networks["backend"]?.ipv6.manifestValue, "fd42::/64")

        let service = try XCTUnwrap(manifest.services.first)
        XCTAssertEqual(service.networks.map(\.network), ["backend", "frontend"])
        XCTAssertEqual(service.networks[0].aliases, ["api", "z-api"])
        XCTAssertTrue(service.networks[1].aliases.isEmpty)

        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertEqual(canonical, try ManifestCanonicalEncoder.encode(manifest))
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #""backend":"#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #""frontend":"#)?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(canonical.range(of: #""api""#)?.lowerBound),
            try XCTUnwrap(canonical.range(of: #""z-api""#)?.lowerBound)
        )
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testLegacyManifestWithoutNetworksKeepsExistingMeaning() throws {
        let source =
            """
            version: 2
            project: legacy-network-default
            services:
              api:
                image: local/api:latest
            """
        let manifest = try ManifestValidator.validated(source)

        XCTAssertTrue(manifest.networks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(manifest.services.first).networks.isEmpty)
        XCTAssertEqual(
            try ManifestValidator.validated(ManifestCanonicalEncoder.encode(manifest)),
            manifest
        )
    }

    func testRejectsInvalidNetworkDriverAndUnknownFieldsStrictly() {
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend:
                driver: bridge
            services:
              api:
                image: local/api:latest
            """,
            contains: "driver must be one of: nat, hostOnly",
            path: "$.networks.backend.driver"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend:
                mtu: 1500
            services:
              api:
                image: local/api:latest
            """,
            code: "HW-MANIFEST-003",
            contains: "Unsupported top-level network field 'mtu'",
            path: "$.networks.backend.mtu"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks: []
            services:
              api:
                image: local/api:latest
            """,
            code: "HW-MANIFEST-001",
            contains: "Expected a mapping",
            path: "$.networks"
        )
    }

    func testRejectsWrongAddressFamiliesAndFullyDisabledNetworks() {
        assertFailure(
            manifest(networks: "ipv4: fd42::/64"),
            contains: "valid IPv4 CIDR",
            path: "$.networks.backend.ipv4"
        )
        assertFailure(
            manifest(networks: "ipv6: 10.42.0.0/24"),
            contains: "valid IPv6 CIDR",
            path: "$.networks.backend.ipv6"
        )
        assertFailure(
            manifest(networks: "ipv4: disabled\n    ipv6: disabled"),
            contains: "must enable at least one address family",
            path: "$.networks.backend"
        )
    }

    func testRejectsInvalidMissingAndDuplicateServiceAttachments() {
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend: {}
            services:
              api:
                image: local/api:latest
                networks:
                  - missing
            """,
            contains: "must reference a declared top-level network",
            path: "$.services.api.networks"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend: {}
            services:
              api:
                image: local/api:latest
                networks:
                  - backend
                  - network: backend
                    aliases: [api, api]
            """,
            contains: "must not attach network 'backend' more than once",
            path: "$.services.api.networks"
        )
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend: {}
            services:
              api:
                image: local/api:latest
                networks:
                  - network: backend
                    aliases: ["Bad_Alias"]
            """,
            contains: "network alias 'Bad_Alias'",
            path: "$.services.api.networks"
        )
        let excessiveAliases = (0...64)
            .map { "alias-\($0)" }
            .joined(separator: ", ")
        assertFailure(
            """
            version: 2
            project: network-demo
            networks:
              backend: {}
            services:
              api:
                image: local/api:latest
                networks:
                  - network: backend
                    aliases: [\(excessiveAliases)]
            """,
            contains: "must declare at most 64 aliases",
            path: "$.services.api.networks"
        )
    }

    private func manifest(networks: String) -> String {
        """
        version: 2
        project: network-demo
        networks:
          backend:
            \(networks)
        services:
          api:
            image: local/api:latest
            networks: [backend]
        """
    }

    private func assertFailure(
        _ source: String,
        code: String = "HW-MANIFEST-002",
        contains text: String,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ManifestValidator.validated(source),
            file: file,
            line: line
        ) { error in
            guard let parseError = error as? ManifestParseError,
                  let issue = parseError.issues.first else {
                return XCTFail(
                    "Expected structured manifest issue, received \(error)",
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(issue.code.rawValue, code, file: file, line: line)
            XCTAssertTrue(issue.message.contains(text), issue.message, file: file, line: line)
            XCTAssertEqual(issue.path, path, file: file, line: line)
        }
    }
}

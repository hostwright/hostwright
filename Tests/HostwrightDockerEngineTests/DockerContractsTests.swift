import Foundation
import XCTest
@testable import HostwrightDockerEngine

final class DockerContractsTests: XCTestCase {
    func testSupportedAPIVersionsAreExactAndNegotiated() throws {
        XCTAssertEqual(
            DockerAPIVersion.supported,
            [.v1_52, .v1_53, .v1_54, .v1_55]
        )
        XCTAssertEqual(try DockerAPIVersion("1.52"), .v1_52)
        XCTAssertEqual(DockerAPIVersion(rawValue: "1.55"), .v1_55)
        XCTAssertFalse(try DockerAPIVersion("1.51").isSupported)
        XCTAssertEqual(
            try DockerAPIVersion.negotiate(requested: "1.52"),
            .v1_52
        )
        XCTAssertEqual(
            try DockerAPIVersion.negotiate(requested: nil),
            .v1_55
        )
        XCTAssertThrowsError(try DockerAPIVersion.negotiate(requested: "1.51")) { error in
            XCTAssertEqual(error as? DockerAPIVersionError, .unsupported("1.51"))
        }
        XCTAssertThrowsError(try DockerAPIVersion.negotiate(requested: "1.56")) { error in
            XCTAssertEqual(error as? DockerAPIVersionError, .unsupported("1.56"))
        }
    }

    func testHTTPParserEnforcesHTTP11ContentLengthAndConnectionClose() throws {
        let request = try DockerHTTPCodec.parseRequest(Data([
            71, 69, 84, 32, 47, 118, 49, 46, 53, 50, 47, 95, 112, 105, 110, 103,
            32, 72, 84, 84, 80, 47, 49, 46, 49, 13, 10,
            72, 111, 115, 116, 58, 32, 100, 111, 99, 107, 101, 114, 13, 10,
            67, 111, 110, 116, 101, 110, 116, 45, 76, 101, 110, 103, 116, 104,
            58, 32, 48, 13, 10, 67, 111, 110, 110, 101, 99, 116, 105, 111, 110,
            58, 32, 99, 108, 111, 115, 101, 13, 10, 13, 10,
        ]))

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.target, "/v1.52/_ping")
        XCTAssertEqual(request.header("host"), "docker")
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertFalse(request.keepAlive)
    }

    func testHTTPValueNormalizesCaseInsensitiveHeadersDeterministically() throws {
        let request = DockerHTTPRequest(
            method: .get,
            target: "/v1.52/_ping",
            headers: ["Host": "first", "host": "last"]
        )

        XCTAssertEqual(request.header("HOST"), "last")
    }

    func testChunkedBodyIsDecodedAndConflictingFramingIsRejected() throws {
        let chunked = Data(
            "POST /v1.52/test HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nbody\r\n0\r\n\r\n".utf8
        )
        XCTAssertEqual(try DockerHTTPCodec.parseRequest(chunked).body, Data("body".utf8))

        let conflicting = Data(
            "POST /v1.52/test HTTP/1.1\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nbody\r\n0\r\n\r\n".utf8
        )
        XCTAssertThrowsError(try DockerHTTPCodec.parseRequest(conflicting)) { error in
            XCTAssertEqual(error as? DockerHTTPProtocolError, .conflictingFramingHeaders)
        }

        let invalidSize = Data(
            "POST /v1.52/test HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n+1\r\nbody\r\n0\r\n\r\n".utf8
        )
        XCTAssertThrowsError(try DockerHTTPCodec.parseRequest(invalidSize)) { error in
            XCTAssertEqual(error as? DockerHTTPProtocolError, .invalidChunk)
        }
    }

    func testMalformedOversizedUpgradeAndCancellationFailBeforeDispatch() throws {
        let oversized = Data(
            ("GET / HTTP/1.1\r\nX-Large: "
             + String(repeating: "x", count: DockerHTTPCodec.maximumHeaderBytes)
             + "\r\n\r\n").utf8
        )
        XCTAssertThrowsError(try DockerHTTPCodec.parseRequest(oversized)) { error in
            XCTAssertEqual(error as? DockerHTTPProtocolError, .headersTooLarge)
        }

        let upgrade = Data(
            "GET /_ping HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n".utf8
        )
        XCTAssertThrowsError(try DockerHTTPCodec.parseRequest(upgrade)) { error in
            XCTAssertEqual(error as? DockerHTTPProtocolError, .unsupportedUpgrade)
        }

        XCTAssertThrowsError(
            try DockerHTTPCodec.parseRequest(
                Data("GET /_ping HTTP/1.1\r\n\r\n".utf8),
                isCancelled: { true }
            )
        ) { error in
            XCTAssertEqual(error as? DockerHTTPProtocolError, .cancelled)
        }
    }

    func testResponseEncodingAndStableJSONErrorsAreBounded() throws {
        let response = DockerHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/plain"],
            body: Data("OK".utf8),
            closeConnection: true
        )
        let encoded = try DockerHTTPCodec.encodeResponse(response)
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\nContent-Type: text/plain\r\n\r\nOK"
        )

        let error = DockerHTTPCodec.errorResponse(.unsupportedOperation)
        XCTAssertEqual(error.statusCode, 404)
        XCTAssertEqual(
            String(decoding: error.body, as: UTF8.self),
            "{\"message\":\"The requested Docker operation is not supported by Hostwright.\"}"
        )

        let injectedReason = DockerHTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK\r\nX-Injected: yes"
        )
        XCTAssertThrowsError(try DockerHTTPCodec.encodeResponse(injectedReason)) { error in
            XCTAssertEqual(error as? DockerHTTPProtocolError, .invalidHeader)
        }
    }

    func testEndpointResolutionAndVersionedContractMatrix() throws {
        XCTAssertEqual(
            try DockerEndpoint.resolve(method: .get, target: "/v1.52/containers/json"),
            .containersList
        )
        XCTAssertEqual(
            try DockerEndpoint.resolve(method: .get, target: "/v1.55/images/library%2Falpine/json"),
            .imageInspect(reference: "library/alpine")
        )
        XCTAssertEqual(
            try DockerEndpoint.resolve(method: .head, target: "/_ping"),
            .ping
        )
        for version in DockerAPIVersion.supported {
            let prefix = "/v" + version.rawValue
            XCTAssertEqual(
                DockerEndpoint.advertised(for: version),
                [
                    "GET \(prefix)/_ping",
                    "HEAD \(prefix)/_ping",
                    "GET \(prefix)/version",
                    "GET \(prefix)/info",
                    "GET \(prefix)/containers/json",
                    "GET \(prefix)/containers/{id}/json",
                    "GET \(prefix)/images/json",
                    "GET \(prefix)/images/{name}/json",
                    "GET \(prefix)/events",
                ]
            )
        }

        XCTAssertThrowsError(
            try DockerEndpoint.resolve(method: .post, target: "/v1.52/containers/create")
        ) { error in
            XCTAssertEqual(error as? DockerEndpointError, .unsupportedOperation)
        }
    }

    func testPublishedContractMatchesFailClosedNonLocalReadBoundary() throws {
        let root = repositoryRoot()
        let contractURL = root.appendingPathComponent(
            "contracts/v0.0.2/phase13-docker-engine-v1.json"
        )
        let data = try Data(contentsOf: contractURL)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let api = try XCTUnwrap(object["api"] as? [String: Any])
        XCTAssertEqual(api["minimum"] as? String, "1.52")
        XCTAssertEqual(api["maximum"] as? String, "1.55")
        XCTAssertEqual(
            api["supported"] as? [String],
            ["1.52", "1.53", "1.54", "1.55"]
        )
        let endpoints = try XCTUnwrap(object["endpoints"] as? [[String: Any]])
        let localPaths: Set<String> = ["/{version}/_ping", "/{version}/version"]
        let nonLocalPaths: Set<String> = [
            "/{version}/info",
            "/{version}/containers/json",
            "/{version}/containers/{id}/json",
            "/{version}/images/json",
            "/{version}/images/{reference}/json",
            "/{version}/events",
        ]

        XCTAssertEqual(
            Set(endpoints.compactMap { $0["path"] as? String }),
            localPaths.union(nonLocalPaths)
        )
        for endpoint in endpoints {
            let path = try XCTUnwrap(endpoint["path"] as? String)
            XCTAssertTrue(endpoint["controlOperation"] is NSNull, path)
            if localPaths.contains(path) {
                XCTAssertEqual(endpoint["authority"] as? String, "local", path)
                XCTAssertEqual(endpoint["status"] as? Int, 200, path)
                XCTAssertNil(endpoint["dispatch"], path)
            } else {
                XCTAssertTrue(nonLocalPaths.contains(path), path)
                XCTAssertEqual(endpoint["authority"] as? String, "unsupported", path)
                XCTAssertEqual(endpoint["status"] as? Int, 404, path)
                XCTAssertEqual(endpoint["dispatch"] as? String, "none", path)
            }
        }

        let errors = try XCTUnwrap(object["errors"] as? [String: Any])
        XCTAssertNil(errors["controlUnavailableStatus"])
        XCTAssertEqual(errors["unsupportedStatus"] as? Int, 404)
        XCTAssertEqual(
            errors["unsupportedMessage"] as? String,
            "The requested Docker operation is not supported by Hostwright."
        )
        XCTAssertEqual(errors["malformedRequestStatus"] as? Int, 400)
        XCTAssertEqual(errors["cancellationStatus"] as? Int, 499)
        XCTAssertEqual(
            errors["cancellationOrdering"] as? String,
            "before-endpoint-dispatch"
        )
        XCTAssertEqual(
            errors["nonEmptyQueryIntent"] as? String,
            "unsupported-before-endpoint-dispatch"
        )
        XCTAssertEqual(errors["redaction"] as? String, "stable-message-only")

        let reference = try String(
            contentsOf: root.appendingPathComponent("docs/reference/docker-engine.md"),
            encoding: .utf8
        )
        XCTAssertTrue(reference.contains("stable JSON `404` before any Control API operation"))
        XCTAssertTrue(reference.contains("Cancellation is checked first and returns\n`499`"))
        XCTAssertTrue(reference.contains("publishes no Control-unavailable\nresponse"))
        XCTAssertFalse(reference.contains("| Phase 09 Control API |"))
        XCTAssertFalse(reference.contains("`503`"))
    }

    func testEndpointQueriesFailClosedWithoutDiscardingIntent() throws {
        XCTAssertEqual(
            try DockerEndpoint.resolve(method: .get, target: "/v1.52/containers/json?"),
            .containersList
        )

        for target in [
            "/v1.52/_ping?verbose=1",
            "/v1.52/version?format=json",
            "/v1.52/info?details=1",
            "/v1.52/containers/json?all=1",
            "/v1.52/containers/abc123/json?size=1",
            "/v1.52/images/json?digests=1",
            "/v1.52/images/library%2Falpine/json?manifests=1",
            "/v1.52/events?since=1",
            "/events?until=2",
        ] {
            XCTAssertThrowsError(
                try DockerEndpoint.resolve(method: .get, target: target),
                target
            ) { error in
                XCTAssertEqual(error as? DockerEndpointError, .unsupportedQuery, target)
            }
        }
    }

    func testEndpointRejectsMalformedAmbiguousDuplicateAndOversizedQueries() throws {
        let malformedTargets = [
            "/v1.52/events?since=%",
            "/v1.52/events?since=%0",
            "/v1.52/events?since=%GG",
            "/v1.52/events?=1",
            "/v1.52/events?since=",
            "/v1.52/events?since",
            "/v1.52/events?since=1&&until=2",
            "/v1.52/events?since=1&since=2",
            "/v1.52/events?since=1&%73ince=2",
            "/v1.52/events?since=1?until=2",
            "/v1.52/events?since=1#fragment",
            "/v1.52/events?bad%00key=1",
            "/v1.52/events?since=bad%0Avalue",
        ]
        for target in malformedTargets {
            XCTAssertThrowsError(
                try DockerEndpoint.resolve(method: .get, target: target),
                target
            ) { error in
                XCTAssertEqual(error as? DockerEndpointError, .invalidTarget, target)
            }
        }

        let oversized = "/v1.52/events?since="
            + String(repeating: "1", count: DockerEndpoint.maximumQueryBytes)
        XCTAssertThrowsError(
            try DockerEndpoint.resolve(method: .get, target: oversized)
        ) { error in
            XCTAssertEqual(error as? DockerEndpointError, .invalidTarget)
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

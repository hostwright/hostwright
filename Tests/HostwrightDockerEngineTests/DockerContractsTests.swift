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
}

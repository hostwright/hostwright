import Foundation
import HostwrightCommandTransport
import HostwrightControlPlane
import XCTest
@testable import HostwrightDockerEngine

final class DockerProxyTests: XCTestCase {
    func testPingVersionAndUnsupportedEndpointsDoNotTouchControlPlane() throws {
        let calls = CallRecorder()
        let adapter = DockerControlAdapter(sendRequest: { request in
            calls.append(request)
            return ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: .object(["ok": .bool(true)])
            )
        })
        let server = try DockerProxyServer(
            configuration: DockerProxyConfiguration(
                socketPath: "/tmp/hostwright-docker-test.sock",
                controlSocketPath: "/private/tmp/hostwright-control-test.sock"
            ),
            adapter: adapter
        )

        let ping = server.handle(try request("GET /v1.52/_ping"))
        XCTAssertEqual(ping.statusCode, 200, String(decoding: ping.body, as: UTF8.self))
        XCTAssertEqual(String(decoding: ping.body, as: UTF8.self), "OK")
        XCTAssertEqual(calls.count, 0)

        for version in DockerAPIVersion.supported {
            let response = server.handle(try request("GET /v" + version.rawValue + "/_ping"))
            XCTAssertEqual(response.statusCode, 200, version.rawValue)
            XCTAssertEqual(response.header("api-version"), version.rawValue)

            let head = server.handle(try request("HEAD /v" + version.rawValue + "/_ping"))
            XCTAssertEqual(head.statusCode, 200, version.rawValue)
            XCTAssertEqual(head.header("api-version"), version.rawValue)

            let versionResponse = server.handle(try request("GET /v" + version.rawValue + "/version"))
            XCTAssertEqual(versionResponse.statusCode, 200, version.rawValue)
            XCTAssertEqual(versionResponse.header("api-version"), version.rawValue)
        }

        let version = server.handle(try request("GET /version"))
        XCTAssertEqual(version.statusCode, 200)
        XCTAssertTrue(String(decoding: version.body, as: UTF8.self).contains("ApiVersion"))
        XCTAssertEqual(calls.count, 0)

        let unsupported = server.handle(try request("POST /v1.52/containers/create"))
        XCTAssertEqual(unsupported.statusCode, 404)
        XCTAssertEqual(calls.count, 0)
    }

    func testUnsupportedAPIVersionAndMalformedTargetAreStable400Responses() throws {
        let calls = CallRecorder()
        let adapter = DockerControlAdapter(sendRequest: { request in
            calls.append(request)
            return ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: .object(["ok": .bool(true)])
            )
        })
        let server = try DockerProxyServer(
            configuration: DockerProxyConfiguration(
                socketPath: "/tmp/hostwright-docker-test.sock",
                controlSocketPath: "/private/tmp/hostwright-control-test.sock"
            ),
            adapter: adapter
        )

        let old = server.handle(try request("GET /v1.51/info"))
        XCTAssertEqual(old.statusCode, 400)
        XCTAssertEqual(String(decoding: old.body, as: UTF8.self), "{\"message\":\"Unsupported Docker API version.\"}")
        XCTAssertEqual(calls.count, 0)

        let new = server.handle(try request("GET /v1.56/info"))
        XCTAssertEqual(new.statusCode, 400)
        XCTAssertEqual(String(decoding: new.body, as: UTF8.self), "{\"message\":\"Unsupported Docker API version.\"}")
        XCTAssertEqual(calls.count, 0)

        let malformed = server.handle(try request("GET /v1.nope/info"))
        XCTAssertEqual(malformed.statusCode, 400)
        XCTAssertEqual(String(decoding: malformed.body, as: UTF8.self), "{\"message\":\"The Docker request target is invalid.\"}")
        XCTAssertEqual(calls.count, 0)
    }

    func testContainerInspectFailsUnsupportedBeforeControlDispatch() throws {
        let recorder = RequestRecorder()
        let adapter = DockerControlAdapter(sendRequest: { request in
            recorder.record(request)
            return ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: .object(["containers": .array([])])
            )
        })
        let server = try DockerProxyServer(
            configuration: DockerProxyConfiguration(
                socketPath: "/tmp/hostwright-docker-test.sock",
                controlSocketPath: "/private/tmp/hostwright-control-test.sock"
            ),
            adapter: adapter
        )

        let response = server.handle(try request("GET /v1.52/containers/abc123/json"))
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(
            String(decoding: response.body, as: UTF8.self),
            "{\"message\":\"The requested Docker operation is not supported by Hostwright.\"}"
        )
        XCTAssertThrowsError(try adapter.route(for: .containerInspect(id: "abc123"))) {
            XCTAssertEqual($0 as? DockerControlAdapterError, .unsupportedEndpoint)
        }
        XCTAssertThrowsError(try adapter.read(endpoint: .containerInspect(id: "abc123"))) {
            XCTAssertEqual($0 as? DockerControlAdapterError, .unsupportedEndpoint)
        }
        XCTAssertEqual(recorder.count, 0)
    }

    func testQueryIntentIsRejectedBeforeAnyControlDispatch() throws {
        let recorder = RequestRecorder()
        let adapter = DockerControlAdapter(sendRequest: { request in
            recorder.record(request)
            return ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: .object(["unexpected": .bool(true)])
            )
        })
        let server = try DockerProxyServer(
            configuration: DockerProxyConfiguration(
                socketPath: "/tmp/hostwright-docker-query-test.sock",
                controlSocketPath: "/private/tmp/hostwright-control-query-test.sock"
            ),
            adapter: adapter
        )

        for target in [
            "/v1.52/_ping?verbose=1",
            "/v1.52/containers/json?all=1",
            "/v1.53/containers/abc123/json?size=1",
            "/v1.54/images/json?digests=1",
            "/v1.55/images/library%2Falpine/json?manifests=1",
            "/events?since=1",
        ] {
            let response = server.handle(try request("GET " + target))
            XCTAssertEqual(response.statusCode, 404, target)
            XCTAssertEqual(
                String(decoding: response.body, as: UTF8.self),
                "{\"message\":\"The requested Docker operation is not supported by Hostwright.\"}",
                target
            )
        }
        XCTAssertEqual(recorder.count, 0)

        for target in [
            "/v1.52/events?since=%",
            "/v1.52/events?since=1&since=2",
            "/v1.52/events?since=1&%73ince=2",
            "/v1.52/events?=1",
            "/v1.52/events?since=",
        ] {
            let response = server.handle(try request("GET " + target))
            XCTAssertEqual(response.statusCode, 400, target)
            XCTAssertEqual(
                String(decoding: response.body, as: UTF8.self),
                "{\"message\":\"The Docker request target is invalid.\"}",
                target
            )
        }
        XCTAssertEqual(recorder.count, 0)

        let emptyQuery = server.handle(try request("GET /v1.52/containers/json?"))
        XCTAssertEqual(emptyQuery.statusCode, 404)
        XCTAssertEqual(recorder.count, 0)
    }

    func testEveryAdvertisedRemoteReadFailsUnsupportedWithoutControlDispatch() throws {
        let recorder = RequestRecorder()
        let adapter = DockerControlAdapter(sendRequest: { request in
            recorder.record(request)
            return ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: .object(["read": .bool(true)])
            )
        })
        let server = try DockerProxyServer(
            configuration: DockerProxyConfiguration(
                socketPath: "/tmp/hostwright-docker-test.sock",
                controlSocketPath: "/private/tmp/hostwright-control-test.sock"
            ),
            adapter: adapter
        )
        let paths = [
            "info",
            "containers/json",
            "containers/abc123/json",
            "images/json",
            "images/library%2Falpine/json",
            "events",
        ]

        for version in DockerAPIVersion.supported {
            for path in paths {
                let response = server.handle(try request("GET /v" + version.rawValue + "/" + path))
                XCTAssertEqual(response.statusCode, 404, path)
                XCTAssertEqual(
                    String(decoding: response.body, as: UTF8.self),
                    "{\"message\":\"The requested Docker operation is not supported by Hostwright.\"}",
                    path
                )
            }
        }
        XCTAssertEqual(recorder.count, 0)
    }

    func testUnsupportedReadIsRedactedAndCancellationNeverReachesControl() throws {
        let calls = CallRecorder()
        let adapter = DockerControlAdapter(sendRequest: { request in
            calls.append(request)
            throw NSError(
                domain: "secret-control-domain",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "credential-fixture-value"]
            )
        })
        let server = try DockerProxyServer(
            configuration: DockerProxyConfiguration(
                socketPath: "/tmp/hostwright-docker-test.sock",
                controlSocketPath: "/private/tmp/hostwright-control-test.sock"
            ),
            adapter: adapter
        )

        let unsupported = server.handle(try request("GET /v1.52/info"))
        XCTAssertEqual(unsupported.statusCode, 404)
        let unsupportedBody = String(decoding: unsupported.body, as: UTF8.self)
        XCTAssertFalse(unsupportedBody.contains("credential-fixture-value"))
        XCTAssertEqual(
            unsupportedBody,
            "{\"message\":\"The requested Docker operation is not supported by Hostwright.\"}"
        )
        XCTAssertEqual(calls.count, 0)

        let cancelled = server.handle(
            try request("GET /v1.52/info"),
            isCancelled: { true }
        )
        XCTAssertEqual(cancelled.statusCode, 499)
        XCTAssertEqual(calls.count, 0)
    }

    func testHeadPingSuppressesBodyWhilePreservingContentLength() throws {
        let adapter = DockerControlAdapter(sendRequest: { request in
            ControlResponseEnvelope(
                requestID: request.requestID,
                status: .completed,
                reasonCode: .completed,
                result: .object(["ok": .bool(true)])
            )
        })
        let server = try DockerProxyServer(
            configuration: DockerProxyConfiguration(
                socketPath: "/tmp/hostwright-docker-test.sock",
                controlSocketPath: "/tmp/hostwright-control-test.sock"
            ),
            adapter: adapter
        )
        let request = try self.request("HEAD /v1.52/_ping")
        let encoded = try server.responseData(for: request)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).hasSuffix("OK"))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("Content-Length: 2\r\n"))
    }

    private func request(_ line: String) throws -> DockerHTTPRequest {
        try DockerHTTPCodec.parseRequest(Data((line + " HTTP/1.1\r\n\r\n").utf8))
    }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func append(_ request: ControlRequestEnvelope) { lock.withLock { value += 1 } }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [ControlRequestEnvelope] = []
    var request: ControlRequestEnvelope? { lock.withLock { requests.last } }
    var count: Int { lock.withLock { requests.count } }
    func record(_ request: ControlRequestEnvelope) { lock.withLock { requests.append(request) } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

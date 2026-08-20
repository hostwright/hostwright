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

    func testReadEndpointUsesCLIControlRouteAndNeverDirectRuntimeAccess() throws {
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

        let response = server.handle(try request("GET /v1.52/containers/json"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(recorder.count, 1)
        let controlRequest = try XCTUnwrap(recorder.request)
        XCTAssertEqual(controlRequest.operation, "status")
        let route = try XCTUnwrap(
            try CLIControlRoute.validate(request: controlRequest)
        )
        XCTAssertEqual(route.dockerEndpoint, "containers.list")
        XCTAssertFalse(route.mutating)
    }

    func testEveryAdvertisedControlReadUsesTheControlRouteAcrossAllVersions() throws {
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
        let reads: [(path: String, operation: String, endpoint: String)] = [
            ("info", "status", "info"),
            ("containers/json", "status", "containers.list"),
            ("containers/abc123/json", "inspect", "containers.inspect"),
            ("images/json", "status", "images.list"),
            ("images/library%2Falpine/json", "image", "images.inspect"),
            ("events", "events", "events"),
        ]

        for version in DockerAPIVersion.supported {
            for read in reads {
                let response = server.handle(try request("GET /v" + version.rawValue + "/" + read.path))
                XCTAssertEqual(response.statusCode, 200, read.path)
                let controlRequest = try XCTUnwrap(recorder.requests.last)
                let route = try XCTUnwrap(try CLIControlRoute.validate(request: controlRequest))
                XCTAssertEqual(route.operation, read.operation)
                XCTAssertEqual(route.dockerEndpoint, read.endpoint)
                XCTAssertFalse(route.mutating)
            }
        }
        XCTAssertEqual(recorder.requests.count, DockerAPIVersion.supported.count * reads.count)
    }

    func testControlUnavailableIsRedactedAndCancellationPrecedesControlCall() throws {
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

        let unavailable = server.handle(try request("GET /v1.52/info"))
        XCTAssertEqual(unavailable.statusCode, 503)
        let unavailableBody = String(decoding: unavailable.body, as: UTF8.self)
        XCTAssertFalse(unavailableBody.contains("credential-fixture-value"))
        XCTAssertEqual(unavailableBody, "{\"message\":\"The Hostwright Control API is unavailable.\"}")
        XCTAssertEqual(calls.count, 1)

        let cancelled = server.handle(
            try request("GET /v1.52/info"),
            isCancelled: { true }
        )
        XCTAssertEqual(cancelled.statusCode, 499)
        XCTAssertEqual(calls.count, 1)
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

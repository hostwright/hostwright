import Foundation
@testable import HostwrightRegistry
import XCTest

final class RegistryTransportTests: XCTestCase {
    func testAuthorizationAndRequestDescriptionsAreRedacted() throws {
        let secret = "transport-secret-value"
        let authorization = try RegistryTransportAuthorization(
            scheme: .bearer,
            value: secret
        )
        let request = RegistryTransportRequest(
            url: try XCTUnwrap(URL(string: "https://registry.example.com/v2/")),
            method: .get,
            authorization: authorization,
            body: Data(secret.utf8)
        )

        XCTAssertEqual(
            authorization.withHeaderValue { $0 },
            "Bearer \(secret)"
        )
        XCTAssertFalse(authorization.description.contains(secret))
        XCTAssertFalse(authorization.debugDescription.contains(secret))
        XCTAssertFalse(request.description.contains(secret))
        XCTAssertFalse(request.debugDescription.contains(secret))
        XCTAssertTrue(request.description.contains("authorization: redacted"))

        let response = RegistryTransportResponse(
            statusCode: 200,
            headers: [:],
            body: Data(secret.utf8)
        )
        XCTAssertFalse(response.description.contains(secret))
        XCTAssertFalse(response.debugDescription.contains(secret))
    }

    func testHTTPSAndBoundedRequestPolicy() throws {
        let valid = RegistryTransportRequest(
            url: try XCTUnwrap(URL(string: "https://registry.example.com/v2/")),
            method: .get,
            headers: ["Accept": "application/json"],
            timeoutMilliseconds: 1_000
        )
        XCTAssertNoThrow(
            try URLSessionRegistryTransport.validate(
                valid,
                maximumRequestBodyBytes: 1_024,
                maximumResponseBodyBytes: 1_024
            )
        )
        let perRequestBound = RegistryTransportRequest(
            url: valid.url,
            method: .get,
            maximumResponseBodyBytes: 512
        )
        XCTAssertNoThrow(try URLSessionRegistryTransport.validate(
            perRequestBound,
            maximumRequestBodyBytes: 1_024,
            maximumResponseBodyBytes: 1_024
        ))
        let excessivePerRequestBound = RegistryTransportRequest(
            url: valid.url,
            method: .get,
            maximumResponseBodyBytes: 1_025
        )
        XCTAssertThrowsError(try URLSessionRegistryTransport.validate(
            excessivePerRequestBound,
            maximumRequestBodyBytes: 1_024,
            maximumResponseBodyBytes: 1_024
        )) { error in
            XCTAssertEqual(error as? RegistryTransportError, .responseBodyTooLarge)
        }

        let insecure = RegistryTransportRequest(
            url: try XCTUnwrap(URL(string: "http://registry.example.com/v2/")),
            method: .get
        )
        XCTAssertThrowsError(
            try URLSessionRegistryTransport.validate(
                insecure,
                maximumRequestBodyBytes: 1_024,
                maximumResponseBodyBytes: 1_024
            )
        ) { error in
            XCTAssertEqual(error as? RegistryTransportError, .insecureTransport)
        }

        let oversized = RegistryTransportRequest(
            url: valid.url,
            method: .post,
            body: Data(repeating: 1, count: 1_025)
        )
        XCTAssertThrowsError(
            try URLSessionRegistryTransport.validate(
                oversized,
                maximumRequestBodyBytes: 1_024,
                maximumResponseBodyBytes: 1_024
            )
        ) { error in
            XCTAssertEqual(error as? RegistryTransportError, .requestBodyTooLarge)
        }
    }

    func testSensitiveAndMalformedHeadersAreRejected() throws {
        let url = try XCTUnwrap(URL(string: "https://registry.example.com/v2/"))
        for headers in [
            ["Authorization": "Bearer secret"],
            ["authorization": "Bearer secret"],
            ["Cookie": "session=secret"],
            ["Proxy-Authorization": "Basic secret"],
            ["X-Bad": "line\r\nInjected: yes"]
        ] {
            let request = RegistryTransportRequest(
                url: url,
                method: .get,
                headers: headers
            )
            XCTAssertThrowsError(
                try URLSessionRegistryTransport.validate(
                    request,
                    maximumRequestBodyBytes: 1_024,
                    maximumResponseBodyBytes: 1_024
                ),
                "Expected rejection for header names: \(headers.keys.sorted())"
            ) { error in
                XCTAssertEqual(error as? RegistryTransportError, .invalidHeader)
                XCTAssertFalse(String(describing: error).contains("secret"))
            }
        }
    }

    func testRedirectPolicyAllowsOnlyThreeSameOriginHTTPSRedirects() throws {
        let source = try XCTUnwrap(URL(string: "https://registry.example.com/v2/"))
        let destination = try XCTUnwrap(URL(string: "https://registry.example.com/auth"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: source,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )
        var proposed = URLRequest(url: destination)
        proposed.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        XCTAssertNoThrow(
            try RegistryRedirectPolicy.redirectedRequest(
                response: response,
                proposedRequest: proposed,
                completedRedirects: 2,
                maximumRedirects: 3
            )
        )
        XCTAssertThrowsError(
            try RegistryRedirectPolicy.redirectedRequest(
                response: response,
                proposedRequest: proposed,
                completedRedirects: 3,
                maximumRedirects: 3
            )
        ) { error in
            XCTAssertEqual(error as? RegistryTransportError, .redirectRejected)
        }
    }

    func testCrossOriginRedirectCannotForwardAuthorization() throws {
        let source = try XCTUnwrap(URL(string: "https://registry.example.com/v2/"))
        let destination = try XCTUnwrap(URL(string: "https://evil.example.com/collect"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: source,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )
        var proposed = URLRequest(url: destination)
        proposed.setValue("Bearer must-not-leak", forHTTPHeaderField: "Authorization")

        XCTAssertThrowsError(
            try RegistryRedirectPolicy.redirectedRequest(
                response: response,
                proposedRequest: proposed,
                completedRedirects: 0,
                maximumRedirects: 3
            )
        ) { error in
            XCTAssertEqual(error as? RegistryTransportError, .redirectRejected)
            XCTAssertFalse(String(describing: error).contains("must-not-leak"))
        }
    }

    func testRedirectPolicyTreatsImplicitAndExplicitHTTPSPortsAsSameOrigin() throws {
        let source = try XCTUnwrap(URL(string: "https://registry.example.com/v2/"))
        let destination = try XCTUnwrap(URL(string: "https://registry.example.com:443/token"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: source,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )

        XCTAssertNoThrow(
            try RegistryRedirectPolicy.redirectedRequest(
                response: response,
                proposedRequest: URLRequest(url: destination),
                completedRedirects: 0,
                maximumRedirects: 3
            )
        )
    }

    func testSynchronousTransportCancelsBeforeNetworkAccess() throws {
        let cancellation = RegistryTransportCancellation()
        cancellation.cancel()
        let request = RegistryTransportRequest(
            url: try XCTUnwrap(URL(string: "https://registry.invalid/v2/")),
            method: .get,
            timeoutMilliseconds: 500
        )

        XCTAssertThrowsError(
            try SynchronousURLSessionRegistryTransport().send(
                request,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(error as? RegistryTransportError, .cancelled)
        }
    }

    func testSynchronousProtocolIsInjectableWithoutAsyncBridge() throws {
        let expected = RegistryTransportResponse(
            statusCode: 401,
            headers: ["www-authenticate": "Bearer realm=\"https://auth.example.com\""],
            body: Data()
        )
        let transport = RecordingSynchronousRegistryTransport(response: expected)
        let request = RegistryTransportRequest(
            url: try XCTUnwrap(URL(string: "https://registry.example.com/v2/")),
            method: .get
        )

        let response = try transport.send(request)

        XCTAssertEqual(response, expected)
        XCTAssertEqual(transport.requests, [request])
    }

    func testInvalidTimeoutFailsBeforeSynchronousTaskCreation() throws {
        let request = RegistryTransportRequest(
            url: try XCTUnwrap(URL(string: "https://registry.example.com/v2/")),
            method: .get,
            timeoutMilliseconds: 0
        )

        XCTAssertThrowsError(
            try SynchronousURLSessionRegistryTransport().send(request)
        ) { error in
            XCTAssertEqual(error as? RegistryTransportError, .invalidTimeout)
        }
    }

    func testResponseHeaderNormalizationIsBounded() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "https://registry.example.com/v2/")),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )

        let headers = try URLSessionRegistryTransport.normalizedHeaders(response)

        XCTAssertEqual(headers["content-type"], "application/json")
    }

    func testStableErrorsDoNotReflectURLOrAuthorization() throws {
        let secret = "do-not-reflect-token"
        let authorization = try RegistryTransportAuthorization(
            scheme: .bearer,
            value: secret
        )
        let request = RegistryTransportRequest(
            url: try XCTUnwrap(URL(string: "http://private-registry.example.com/v2/")),
            method: .get,
            authorization: authorization
        )

        XCTAssertThrowsError(
            try URLSessionRegistryTransport.validate(
                request,
                maximumRequestBodyBytes: 1_024,
                maximumResponseBodyBytes: 1_024
            )
        ) { error in
            let rendered = String(describing: error)
            XCTAssertFalse(rendered.contains(secret))
            XCTAssertFalse(rendered.contains("private-registry.example.com"))
        }
    }
}

private final class RecordingSynchronousRegistryTransport:
    RegistrySynchronousHTTPTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let response: RegistryTransportResponse
    private var storedRequests: [RegistryTransportRequest] = []

    init(response: RegistryTransportResponse) {
        self.response = response
    }

    var requests: [RegistryTransportRequest] {
        lock.withLock { storedRequests }
    }

    func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        if cancellation.isCancelled {
            throw RegistryTransportError.cancelled
        }
        lock.withLock { storedRequests.append(request) }
        return response
    }
}

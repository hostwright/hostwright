import Foundation
import XCTest
@testable import HostwrightRuntime

extension HostwrightRuntimeTests {
    func testBoundedHealthCheckerRunsAllowedLoopbackURLAndRedactsOutput() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 200, body: "ok token=fake-secret"))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(
                command: ["curl", "-f", "http://localhost:8080/health?token=fake-secret"],
                timeoutSeconds: 2
            )
        )

        XCTAssertEqual(result.status, .healthy)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(fetcher.requests.map(\.url.absoluteString), ["http://localhost:8080/health?token=fake-secret"])
        XCTAssertEqual(fetcher.requests.map(\.timeout.seconds), [2])
        XCTAssertTrue(result.standardOutput.contains("[REDACTED]"))
        XCTAssertFalse(result.standardOutput.contains("fake-secret"))
        XCTAssertFalse(result.command.joined(separator: " ").contains("fake-secret"))
    }

    func testURLSessionHealthFetcherRejectsRedirects() async throws {
        let delegate = RejectingRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let originalURL = try XCTUnwrap(URL(string: "http://localhost:8080/health"))
        let redirectedURL = try XCTUnwrap(URL(string: "http://example.com/health"))
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": redirectedURL.absoluteString]
            )
        )
        let request = URLRequest(url: redirectedURL)

        let redirectedRequest = await delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request
        )

        XCTAssertNil(redirectedRequest)
        session.invalidateAndCancel()
    }

    func testURLSessionHealthFetcherReadsRealLoopbackHTTPResponse() async throws {
        let server = try LoopbackHTTPServer(statusCode: 200, body: "ready")
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/health"))

        let response = try await URLSessionRuntimeHealthURLFetcher().fetch(
            url: url,
            timeout: RuntimeCommandTimeout(seconds: 2)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "ready")
        XCTAssertEqual(server.requestCount, 1)
    }

    func testURLSessionHealthFetcherRejectsNonLoopbackURLBeforeNetwork() async throws {
        let fetcher = URLSessionRuntimeHealthURLFetcher()
        let url = try XCTUnwrap(URL(string: "https://example.com/health"))

        do {
            _ = try await fetcher.fetch(url: url, timeout: RuntimeCommandTimeout(seconds: 1))
            XCTFail("Expected non-loopback health URL to be rejected.")
        } catch let error as RuntimeAdapterError {
            guard case .commandRejected(let classification, let message) = error else {
                return XCTFail("Expected commandRejected, got \(error).")
            }
            XCTAssertEqual(classification, .readOnly)
            XCTAssertTrue(message.contains("loopback"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testBoundedHealthCheckerTreatsRedirectStatusAsUnhealthy() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 302))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(command: ["curl", "-f", "http://localhost:8080/health"])
        )

        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertEqual(result.exitStatus, 302)
        XCTAssertTrue(result.standardError.contains("HTTP status 302"))
    }

    func testBoundedHealthCheckerRejectsUnsafeCurlAndWgetArgumentsWithoutRunning() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 200))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )
        let rejectedCommands = [
            ["curl", "-K", "/tmp/curlrc", "http://localhost:8080/health"],
            ["curl", "-o", "/tmp/output", "http://localhost:8080/health"],
            ["curl", "file:///etc/passwd"],
            ["curl", "http://example.com/health"],
            ["wget", "--post-file=/etc/passwd", "http://localhost:8080/health"],
            ["wget", "http://localhost:8080/health"]
        ]

        for command in rejectedCommands {
            let result = await checker.check(identity: identity, spec: RuntimeHealthCheckSpec(command: command))
            XCTAssertEqual(result.status, .unknown)
            XCTAssertTrue(result.standardError.contains("health checks") || result.standardError.contains("Health check URLs"))
        }
        XCTAssertEqual(fetcher.requests.count, 0)
    }

    func testBoundedHealthCheckerRejectsShellExecutableWithoutRunning() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 200))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(command: ["sh", "-c", "rm -rf /tmp/hostwright"])
        )

        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.standardError.contains("not allowed"))
        XCTAssertEqual(fetcher.requests.count, 0)
    }

    func testBoundedHealthCheckerMapsTimeoutToUnhealthyAndRedactsPartialOutput() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(error: URLError(.timedOut))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(command: ["curl", "-f", "http://localhost:8080/health?token=fake-secret"], timeoutSeconds: 1)
        )

        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("timed out"))
        XCTAssertFalse(result.command.joined(separator: " ").contains("fake-secret"))
        XCTAssertFalse(result.standardError.contains("fake-password"))
    }
}

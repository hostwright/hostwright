import Darwin
import Foundation
import HostwrightControl
import HostwrightCore
import XCTest

final class ControlRequestTests: XCTestCase {
    func testParserAcceptsVersionedBoundedEventRequest() throws {
        let request = try LocalControlRequestParser.parse(
            Data(#"{"apiVersion":2,"requestID":"request-1","operation":"events","project":"demo","eventType":"apply.succeeded","service":"api","severity":"info","limit":25,"sort":"desc"}"#.utf8)
        )

        XCTAssertEqual(request.requestID, "request-1")
        XCTAssertEqual(request.operation, .events)
        XCTAssertEqual(request.project, "demo")
        XCTAssertEqual(request.limit, 25)
        XCTAssertEqual(request.sort, "desc")
    }

    func testParserRejectsUnknownDuplicateMissingMutatingAndOversizedRequests() {
        let invalid: [Data] = [
            Data(#"{"apiVersion":2,"requestID":"r1","operation":"plan","path":"/tmp/manifest"}"#.utf8),
            Data(#"{"apiVersion":2,"apiVersion":2,"requestID":"r1","operation":"plan"}"#.utf8),
            Data(#"{"apiVersion":2,"\u0061piVersion":1,"requestID":"r1","operation":"plan"}"#.utf8),
            Data(#"{"apiVersion":2,"operation":"plan"}"#.utf8),
            Data(#"{"apiVersion":2,"requestID":"r1","operation":"apply"}"#.utf8),
            Data(repeating: 65, count: LocalControlRequestParser.maximumRequestBytes + 1)
        ]

        for data in invalid {
            assertDiagnostic(tryRun: { try LocalControlRequestParser.parse(data) }, code: .controlAPIInvalid)
        }
    }

    func testParserRejectsUnsupportedVersionIdentifierAndFilterCombinations() {
        let invalid = [
            #"{"apiVersion":3,"requestID":"r1","operation":"plan"}"#,
            #"{"apiVersion":2,"requestID":"token=must-not-be-an-id","operation":"plan"}"#,
            #"{"apiVersion":2,"requestID":"r1","operation":"plan","project":"demo"}"#,
            #"{"apiVersion":2,"requestID":"r1","operation":"recovery","limit":5}"#,
            #"{"apiVersion":2,"requestID":"r1","operation":"events","severity":"critical"}"#,
            #"{"apiVersion":2,"requestID":"r1","operation":"events","limit":1001}"#,
            #"{"apiVersion":2,"requestID":"r1","operation":"events","sort":"newest"}"#
        ]
        for text in invalid {
            assertDiagnostic(
                tryRun: { try LocalControlRequestParser.parse(Data(text.utf8)) },
                code: .controlAPIInvalid
            )
        }
    }

    func testCommandArgumentsKeepPathsInLaunchConfiguration() throws {
        let configuration = LocalControlConfiguration(
            manifestPath: "/tmp/hostwright.yaml",
            stateDatabasePath: "/tmp/state.sqlite",
            teamProfilePath: "/tmp/team.json"
        )
        XCTAssertEqual(
            try LocalControlAPI.commandArguments(
                for: LocalControlRequest(requestID: "plan-1", operation: .plan),
                configuration: configuration
            ),
            ["plan", "/tmp/hostwright.yaml", "--output", "json", "--team-profile", "/tmp/team.json"]
        )
        XCTAssertEqual(
            try LocalControlAPI.commandArguments(
                for: LocalControlRequest(requestID: "status-1", operation: .status),
                configuration: configuration
            ),
            ["status", "/tmp/hostwright.yaml", "--state-db", "/tmp/state.sqlite", "--output", "json"]
        )
        XCTAssertEqual(
            try LocalControlAPI.commandArguments(
                for: LocalControlRequest(requestID: "events-1", operation: .events, project: "demo"),
                configuration: configuration
            ),
            ["events", "--state-db", "/tmp/state.sqlite", "--project", "demo", "--limit", "100", "--output", "json"]
        )
    }

    func testStateOperationsRequireConfiguredStatePath() {
        let configuration = LocalControlConfiguration(manifestPath: "/tmp/hostwright.yaml")
        for operation in [LocalControlOperation.events, .recovery] {
            assertDiagnostic(
                tryRun: {
                    try LocalControlAPI.commandArguments(
                        for: LocalControlRequest(requestID: "request-1", operation: operation),
                        configuration: configuration
                    )
                },
                code: .controlAPIUnavailable
            )
        }
    }

    func testToolParserRequiresExplicitAbsoluteLaunchPaths() throws {
        XCTAssertEqual(try LocalControlToolCommand.parse(arguments: []), .help)
        XCTAssertEqual(try LocalControlToolCommand.parse(arguments: ["--version"]), .version)
        XCTAssertEqual(
            try LocalControlToolCommand.parse(arguments: [
                "--manifest", "/tmp/hostwright.yaml",
                "--state-db", "/tmp/state.sqlite",
                "--team-profile", "/tmp/team.json"
            ]),
            .run(
                LocalControlConfiguration(
                    manifestPath: "/tmp/hostwright.yaml",
                    stateDatabasePath: "/tmp/state.sqlite",
                    teamProfilePath: "/tmp/team.json"
                )
            )
        )
        XCTAssertThrowsError(try LocalControlToolCommand.parse(arguments: ["--manifest", "relative.yaml"]))
        XCTAssertThrowsError(try LocalControlToolCommand.parse(arguments: ["--state-db", "/tmp/state.sqlite"]))
        XCTAssertThrowsError(try LocalControlToolCommand.parse(arguments: ["--manifest", "/tmp/a", "--manifest", "/tmp/b"]))
    }

    func testControlJSONValueRoundTripsNestedCLIShape() throws {
        let data = Data(#"{"array":[1,true,null,2.5],"object":{"message":"redacted"}}"#.utf8)
        let value = try JSONDecoder().decode(ControlJSONValue.self, from: data)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(
            try JSONDecoder().decode(ControlJSONValue.self, from: encoded),
            value
        )
    }

    func testInputReaderReadsOneRealPipeToEOF() throws {
        let descriptors = try makePipe()
        defer { Darwin.close(descriptors.read) }
        let request = Data(#"{"apiVersion":2,"requestID":"pipe-1","operation":"plan"}"#.utf8)

        try writeAll(request, to: descriptors.write)
        Darwin.close(descriptors.write)

        XCTAssertEqual(
            try LocalControlInputReader.read(
                descriptor: descriptors.read,
                timeoutMilliseconds: 500,
                maximumBytes: 1_024
            ),
            request
        )
    }

    func testInputReaderRejectsOversizedRealPipe() throws {
        let descriptors = try makePipe()
        defer { Darwin.close(descriptors.read) }
        try writeAll(Data("12345".utf8), to: descriptors.write)
        Darwin.close(descriptors.write)

        assertDiagnostic(
            tryRun: {
                try LocalControlInputReader.read(
                    descriptor: descriptors.read,
                    timeoutMilliseconds: 500,
                    maximumBytes: 4
                )
            },
            code: .controlAPIInvalid
        )
    }

    func testInputReaderTimesOutWhenRealPipeRemainsOpenWithoutInput() throws {
        let descriptors = try makePipe()
        defer {
            Darwin.close(descriptors.read)
            Darwin.close(descriptors.write)
        }

        assertDiagnostic(
            tryRun: {
                try LocalControlInputReader.read(
                    descriptor: descriptors.read,
                    timeoutMilliseconds: 10,
                    maximumBytes: 1_024
                )
            },
            code: .controlAPIInvalid
        )
    }

    private func assertDiagnostic<T>(tryRun: () throws -> T, code: HostwrightErrorCode) {
        XCTAssertThrowsError(try tryRun()) { error in
            guard let diagnostic = error as? HostwrightDiagnostic else {
                return XCTFail("Expected HostwrightDiagnostic, got \(error)")
            }
            XCTAssertEqual(diagnostic.code.rawValue, code.rawValue)
            XCTAssertFalse(diagnostic.message.contains("must-not-be-an-id"))
        }
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(.EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }
}

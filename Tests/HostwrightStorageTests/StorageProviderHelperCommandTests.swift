import Foundation
import XCTest
@testable import HostwrightStorage

final class StorageProviderHelperCommandTests: XCTestCase {
    func testVersionCommandIsExact() throws {
        XCTAssertEqual(
            try StorageProviderHelperCommand.parse(
                arguments: ["--version"]
            ),
            .version
        )
        XCTAssertEqual(
            StorageProviderHelperCommand.versionText,
            "\(LocalStorageProviderContract.providerVersion)\n"
        )
        XCTAssertThrowsError(
            try StorageProviderHelperCommand.parse(
                arguments: ["--version", "extra"]
            )
        )
    }

    func testRunCommandAcceptsEveryRequiredFlagInAnyOrder() throws {
        let command = try StorageProviderHelperCommand.parse(
            arguments: [
                "run",
                "--capacity-bytes", "4096",
                "--provider-root", "/private/provider",
                "--provider", "hostwright-local",
                "--runtime-dir", "/private/runtime"
            ]
        )
        guard case let .run(configuration) = command else {
            return XCTFail("Expected run command")
        }
        XCTAssertEqual(
            configuration.runtimeDirectoryURL.path,
            "/private/runtime"
        )
        XCTAssertEqual(
            configuration.providerRootURL.path,
            "/private/provider"
        )
        XCTAssertEqual(configuration.capacityBytes, 4096)
    }

    func testRunCommandRejectsMissingDuplicateAndUnknownArguments() {
        let invalidArguments: [[String]] = [
            ["run"],
            [
                "run",
                "--provider", "hostwright-local",
                "--runtime-dir", "/private/runtime",
                "--provider-root", "/private/provider",
                "--provider-root", "/private/other"
            ],
            [
                "run",
                "--provider", "hostwright-local",
                "--runtime-dir", "/private/runtime",
                "--provider-root", "/private/provider",
                "--unknown", "4096"
            ]
        ]
        for arguments in invalidArguments {
            XCTAssertThrowsError(
                try StorageProviderHelperCommand.parse(
                    arguments: arguments
                ),
                "Unexpectedly accepted \(arguments)"
            )
        }
    }

    func testRunCommandRejectsUnsupportedProviderPathAndCapacity() {
        XCTAssertThrowsError(
            try parse(
                provider: "third-party",
                runtime: "/private/runtime",
                root: "/private/provider",
                capacity: "4096"
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderHelperCommandError,
                .unsupportedProvider
            )
        }

        for path in [
            "relative",
            "/private/../runtime",
            "/private//runtime",
            "/private/runtime/"
        ] {
            XCTAssertThrowsError(
                try parse(
                    runtime: path,
                    root: "/private/provider",
                    capacity: "4096"
                )
            )
        }

        for capacity in ["0", "-1", "+1", "01", "not-a-number"] {
            XCTAssertThrowsError(
                try parse(
                    runtime: "/private/runtime",
                    root: "/private/provider",
                    capacity: capacity
                )
            )
        }
    }

    func testRunCommandRejectsOverlappingPrivateDirectories() {
        XCTAssertThrowsError(
            try parse(
                runtime: "/private/hostwright",
                root: "/private/hostwright/provider",
                capacity: "4096"
            )
        ) {
            XCTAssertEqual(
                $0 as? StorageProviderHelperCommandError,
                .overlappingDirectories
            )
        }
    }

    private func parse(
        provider: String = "hostwright-local",
        runtime: String,
        root: String,
        capacity: String
    ) throws -> StorageProviderHelperCommand {
        try StorageProviderHelperCommand.parse(
            arguments: [
                "run",
                "--provider", provider,
                "--runtime-dir", runtime,
                "--provider-root", root,
                "--capacity-bytes", capacity
            ]
        )
    }
}

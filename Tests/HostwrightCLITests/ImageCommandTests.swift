import HostwrightCLI
import HostwrightRuntime
import XCTest

final class ImageCommandTests: XCTestCase {
    func testEveryImageOperationHasOneStrictCLIShape() throws {
        let commands: [[String]] = [
            ["image", "inspect", "registry.example/app:v1", "--json"],
            [
                "image", "pull", "registry.example/app:v1",
                "--scheme", "https",
                "--progress", "plain",
                "--platform", "linux/arm64",
                "--json"
            ],
            [
                "image", "push", "registry.example/app:v1",
                "--scheme", "https",
                "--progress", "none",
                "--platform", "linux/arm64",
                "--json"
            ],
            ["image", "tag", "registry.example/app:v1", "registry.example/app:stable", "--json"],
            [
                "image", "load",
                "--input", "/private/tmp/app.oci",
                "--reference", "registry.example/app:v1",
                "--json"
            ],
            [
                "image", "save", "registry.example/app:v1",
                "--output", "/private/tmp/app.oci",
                "--platform", "linux/arm64",
                "--json"
            ],
            [
                "image", "build",
                "--context", "/private/tmp/context",
                "--file", "/private/tmp/context/Containerfile",
                "--tag", "registry.example/app:v2",
                "--platform", "linux/arm64",
                "--no-cache",
                "--json"
            ],
            ["image", "delete", "registry.example/app:v1", "--json"],
            ["image", "prune", "--dry-run", "--json"],
            ["image", "cache", "status", "--maximum-bytes", "1024", "--json"],
            ["image", "cache", "pin", "registry.example/app:v1", "--json"],
            ["image", "cache", "unpin", "registry.example/app:v1", "--json"]
        ]

        for arguments in commands {
            guard case .image = try CLICommand.parse(arguments: arguments) else {
                return XCTFail("Expected image command for \(arguments).")
            }
        }
    }

    func testPruneParsesBoundedPressurePolicyAndExactConfirmation() throws {
        let confirmation = String(repeating: "a", count: 64)
        guard case .image(let command) = try CLICommand.parse(
            arguments: [
                "image", "prune",
                "--confirm-plan", confirmation,
                "--maximum-bytes", "1024",
                "--target-bytes", "512",
                "--retain-seconds", "3600",
                "--max-delete", "4",
                "--runtime-provider", "apple-cli",
                "--json"
            ]
        ), case .prune(let options) = command.action else {
            return XCTFail("Expected strict image prune options.")
        }

        XCTAssertEqual(options.confirmationPlanSHA256, confirmation)
        XCTAssertFalse(options.dryRun)
        XCTAssertEqual(options.maximumBytes, 1_024)
        XCTAssertEqual(options.targetBytes, 512)
        XCTAssertEqual(options.retentionSeconds, 3_600)
        XCTAssertEqual(options.maximumDeletions, 4)
    }

    func testPullAndPushExposeDeterministicOfflineBehavior() throws {
        guard case .image(let pull) = try CLICommand.parse(
            arguments: [
                "image", "pull", "registry.example/app:v1",
                "--offline",
                "--json"
            ]
        ), case .pull(_, .https, .plain, nil, true) = pull.action else {
            return XCTFail("Expected strict offline pull options.")
        }

        guard case .image(let push) = try CLICommand.parse(
            arguments: [
                "image", "push", "registry.example/app:v1",
                "--offline",
                "--json"
            ]
        ), case .push(_, .https, .plain, nil, true) = push.action else {
            return XCTFail("Expected strict offline push options.")
        }
    }

    func testImageReferencesAndPlatformsFailClosedAtCLIParsing() {
        let invalid: [[String]] = [
            ["image", "inspect", "https://registry.example/app:v1"],
            ["image", "inspect", "user:password@registry.example/app:v1"],
            ["image", "pull", "registry.example/app:v1", "--platform", "linux/arm64/v8"],
            ["image", "pull", "registry.example/app:v1", "--scheme", "http"],
            ["image", "pull", "registry.example/app:v1", "--progress", "auto"]
        ]

        for arguments in invalid {
            XCTAssertThrowsError(try CLICommand.parse(arguments: arguments))
        }
    }

    func testImagePathsMustBeNormalizedAbsoluteAndBuildFileMustStayInContext() {
        let invalid: [[String]] = [
            ["image", "load", "--input", "app.oci"],
            ["image", "load", "--input", "/private/tmp/../app.oci"],
            ["image", "load", "--input", "/private/tmp/app.oci"],
            ["image", "save", "app:v1", "--output", "app.oci"],
            ["image", "build", "--context", ".", "--tag", "app:v1"],
            [
                "image", "build",
                "--context", "/private/tmp/context",
                "--file", "/private/tmp/other/Containerfile",
                "--tag", "app:v1"
            ]
        ]

        for arguments in invalid {
            XCTAssertThrowsError(try CLICommand.parse(arguments: arguments))
        }
    }

    func testBroadNativeAndCredentialRiskOptionsAreNeverAccepted() {
        let invalid: [[String]] = [
            ["image", "load", "--input", "/private/tmp/app.oci", "--force"],
            ["image", "prune", "--all"],
            ["image", "prune", "--all-managed"],
            ["image", "prune", "--dry-run", "--confirm-plan", String(repeating: "a", count: 64)],
            ["image", "prune", "--maximum-bytes", "1024"],
            ["image", "prune", "--target-bytes", "512"],
            ["image", "prune", "--maximum-bytes", "512", "--target-bytes", "1024"],
            ["image", "prune", "--max-delete", "257"],
            ["image", "cache", "status", "--maximum-bytes", "0"],
            ["image", "cache", "pin"],
            ["image", "cache", "unpin", "app:v1", "app:v2"],
            ["image", "delete", "app:v1", "--force"],
            [
                "image", "build",
                "--context", "/private/tmp/context",
                "--tag", "app:v1",
                "--build-arg", "TOKEN=secret"
            ],
            [
                "image", "pull", "app:v1",
                "--scheme", "https",
                "--scheme", "https"
            ]
        ]

        for arguments in invalid {
            XCTAssertThrowsError(try CLICommand.parse(arguments: arguments))
        }
    }
}

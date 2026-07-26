import Foundation
import HostwrightCLI
import HostwrightCore
import HostwrightStorage
import XCTest
@testable import HostwrightControl

final class ControlStorageParityTests: XCTestCase {
    private let volume1 =
        "11111111-1111-4111-8111-111111111111"
    private let volume2 =
        "22222222-2222-4222-8222-222222222222"
    private let resource =
        "33333333-3333-4333-8333-333333333333"
    private let reference =
        "44444444-4444-4444-8444-444444444444"
    private let confirmation = String(repeating: "a", count: 64)

    func testEveryVolumeOperationMapsToStrictCLIGrammar() throws {
        let requests = [
            request("list", project: "project-a"),
            request("inspect", ids: [volume1]),
            request("capacity"),
            request("health"),
            request(
                "recover",
                ids: [volume1],
                idempotencyKey: "operation-a"
            ),
            request("delete", ids: [volume1], dryRun: true),
            request("prune", confirmPlan: confirmation),
            request(
                "snapshot-create",
                ids: [volume1],
                resourceID: resource,
                name: "daily"
            ),
            request("snapshot-list", ids: [volume1]),
            request(
                "snapshot-inspect",
                ids: [volume1],
                resourceID: resource
            ),
            request(
                "snapshot-retain",
                ids: [volume1],
                resourceID: resource,
                owner: "policy-a"
            ),
            request(
                "snapshot-export",
                ids: [volume1],
                resourceID: resource,
                outputPath: "/private/tmp/snapshot-export"
            ),
            request(
                "snapshot-restore",
                ids: [volume1],
                resourceID: resource,
                targetVolumeID: volume2,
                referenceID: reference,
                dryRun: true
            ),
            request(
                "snapshot-delete",
                ids: [volume1],
                resourceID: resource,
                confirmPlan: confirmation
            ),
            request(
                "backup-create",
                ids: [volume1, volume2],
                resourceID: resource,
                name: "nightly",
                keyReference: "keychain://hostwright/backup"
            ),
            request("backup-list", ids: [volume1]),
            request(
                "backup-inspect",
                ids: [volume1],
                resourceID: resource
            ),
            request(
                "backup-verify",
                ids: [volume1],
                resourceID: resource,
                keyReference: "keychain://hostwright/backup"
            ),
            request(
                "backup-retain",
                ids: [volume1],
                resourceID: resource,
                owner: "policy-a"
            ),
            request(
                "backup-restore",
                resourceID: resource,
                keyReference: "keychain://hostwright/backup",
                restoreTargets: ["\(volume1)=\(volume2)"],
                dryRun: true
            ),
            request(
                "backup-delete",
                ids: [volume1],
                resourceID: resource,
                confirmPlan: confirmation
            ),
        ]
        let configuration = LocalControlConfiguration(
            manifestPath: "/unused-for-volume-operations",
            stateDatabasePath: "/private/tmp/hostwright-state.sqlite"
        )

        for request in requests {
            let encoded = try JSONEncoder().encode(request)
            XCTAssertEqual(
                try LocalControlRequestParser.parse(encoded),
                request,
                request.requestID
            )
            let arguments = try LocalControlAPI.commandArguments(
                for: request,
                configuration: configuration
            )
            guard case .volume = try CLICommand.parse(
                arguments: arguments
            ) else {
                return XCTFail(
                    "Control request did not map to volume CLI: \(request.requestID)."
                )
            }
            XCTAssertTrue(arguments.contains("--state-db"))
            XCTAssertTrue(arguments.contains("--json"))
        }
    }

    func testVolumeControlRejectsCrossOperationAndUnsafeFields() {
        let invalid = [
            request("inspect"),
            request("capacity", ids: [volume1]),
            request("delete", ids: [volume1]),
            request(
                "snapshot-create",
                ids: [volume1],
                resourceID: resource
            ),
            request(
                "snapshot-export",
                ids: [volume1],
                resourceID: resource,
                outputPath: "relative"
            ),
            request(
                "backup-create",
                ids: [volume1],
                resourceID: resource,
                name: "nightly",
                keyReference: "plaintext"
            ),
            request(
                "backup-restore",
                resourceID: resource,
                keyReference: "keychain://hostwright/backup",
                restoreTargets: [
                    "\(volume1)=\(volume2)",
                    "\(volume1)=\(volume1)",
                ],
                dryRun: true
            ),
            LocalControlRequest(
                requestID: "volume-cross-image",
                operation: .volume,
                imageOperation: "inspect",
                volumeOperation: "capacity"
            ),
        ]

        for request in invalid {
            XCTAssertThrowsError(
                try LocalControlRequestParser.validate(request),
                request.requestID
            )
        }
    }

    func testRemoteS3BackupOperationsMapToStrictCLIGrammar() throws {
        let accessKey =
            "keychain://hostwright.phase06/s3-access"
        let secretKey =
            "keychain://hostwright.phase06/s3-secret"
        let requests = [
            request(
                "backup-create",
                ids: [volume1, volume2],
                resourceID: resource,
                name: "nightly",
                keyReference: "keychain://hostwright/backup",
                remoteS3Endpoint: "https://s3.example.com",
                remoteS3Bucket: "hostwright-backups",
                remoteS3Region: "us-east-1",
                remoteS3AccessKeyReference: accessKey,
                remoteS3SecretKeyReference: secretKey
            ),
            request(
                "backup-verify",
                ids: [volume1],
                resourceID: resource,
                keyReference: "keychain://hostwright/backup",
                remoteS3Endpoint: "https://s3.example.com",
                remoteS3Bucket: "hostwright-backups",
                remoteS3Region: "us-east-1",
                remoteS3Prefix: "phase06/control",
                remoteS3AccessKeyReference: accessKey,
                remoteS3SecretKeyReference: secretKey
            ),
            request(
                "backup-retain",
                ids: [volume1],
                resourceID: resource,
                owner: "policy-a",
                remoteS3Endpoint: "https://s3.example.com",
                remoteS3Bucket: "hostwright-backups",
                remoteS3Region: "us-east-1",
                remoteS3Prefix: "phase06/control",
                remoteS3AccessKeyReference: accessKey,
                remoteS3SecretKeyReference: secretKey
            ),
            request(
                "backup-restore",
                resourceID: resource,
                keyReference: "keychain://hostwright/backup",
                restoreTargets: ["\(volume1)=\(volume2)"],
                dryRun: true,
                remoteS3Endpoint: "https://s3.example.com",
                remoteS3Bucket: "hostwright-backups",
                remoteS3Region: "us-east-1",
                remoteS3Prefix: "phase06/control",
                remoteS3AccessKeyReference: accessKey,
                remoteS3SecretKeyReference: secretKey
            ),
            request(
                "backup-delete",
                ids: [volume1],
                resourceID: resource,
                confirmPlan: confirmation,
                remoteS3Endpoint: "https://s3.example.com",
                remoteS3Bucket: "hostwright-backups",
                remoteS3Region: "us-east-1",
                remoteS3Prefix: "phase06/control",
                remoteS3AccessKeyReference: accessKey,
                remoteS3SecretKeyReference: secretKey
            ),
        ]
        let configuration = LocalControlConfiguration(
            manifestPath: "/unused-for-volume-operations",
            stateDatabasePath:
                "/private/tmp/hostwright-state.sqlite"
        )

        for request in requests {
            let encoded = try JSONEncoder().encode(request)
            XCTAssertEqual(
                try LocalControlRequestParser.parse(encoded),
                request,
                request.requestID
            )
            let arguments = try LocalControlAPI.commandArguments(
                for: request,
                configuration: configuration
            )
            guard case .volume = try CLICommand.parse(
                arguments: arguments
            ) else {
                return XCTFail(
                    "Control request did not map to volume CLI: \(request.requestID)."
                )
            }
            XCTAssertEqual(
                value(after: "--remote-s3-endpoint", in: arguments),
                "https://s3.example.com"
            )
            XCTAssertEqual(
                value(after: "--remote-s3-bucket", in: arguments),
                "hostwright-backups"
            )
            XCTAssertEqual(
                value(after: "--remote-s3-region", in: arguments),
                "us-east-1"
            )
            if let prefix = request.volumeRemoteS3Prefix {
                XCTAssertEqual(
                    value(after: "--remote-s3-prefix", in: arguments),
                    prefix
                )
            } else {
                XCTAssertFalse(
                    arguments.contains("--remote-s3-prefix")
                )
            }
            XCTAssertEqual(
                value(
                    after: "--remote-s3-access-key-ref",
                    in: arguments
                ),
                accessKey
            )
            XCTAssertEqual(
                value(
                    after: "--remote-s3-secret-key-ref",
                    in: arguments
                ),
                secretKey
            )
        }
    }

    func testRemoteS3BackupFieldsFailClosed() {
        let accessKey =
            "keychain://hostwright.phase06/s3-access"
        let secretKey =
            "keychain://hostwright.phase06/s3-secret"
        let complete = (
            endpoint: "https://s3.example.com",
            bucket: "hostwright-backups",
            region: "us-east-1",
            prefix: "phase06/control",
            accessKey: accessKey,
            secretKey: secretKey
        )
        let invalid = [
            request(
                "backup-create",
                ids: [volume1],
                resourceID: resource,
                name: "nightly",
                keyReference: "keychain://hostwright/backup",
                remoteS3Endpoint: complete.endpoint
            ),
            request(
                "backup-verify",
                ids: [volume1],
                resourceID: resource,
                keyReference: "keychain://hostwright/backup",
                remoteS3Endpoint: "http://s3.example.com",
                remoteS3Bucket: complete.bucket,
                remoteS3Region: complete.region,
                remoteS3Prefix: complete.prefix,
                remoteS3AccessKeyReference: complete.accessKey,
                remoteS3SecretKeyReference: complete.secretKey
            ),
            request(
                "backup-retain",
                ids: [volume1],
                resourceID: resource,
                owner: "policy-a",
                remoteS3Endpoint: complete.endpoint,
                remoteS3Bucket: "Bad_Bucket",
                remoteS3Region: complete.region,
                remoteS3Prefix: complete.prefix,
                remoteS3AccessKeyReference: complete.accessKey,
                remoteS3SecretKeyReference: complete.secretKey
            ),
            request(
                "backup-restore",
                resourceID: resource,
                keyReference: "keychain://hostwright/backup",
                restoreTargets: ["\(volume1)=\(volume2)"],
                dryRun: true,
                remoteS3Endpoint: complete.endpoint,
                remoteS3Bucket: complete.bucket,
                remoteS3Region: complete.region,
                remoteS3Prefix: "../escape",
                remoteS3AccessKeyReference: complete.accessKey,
                remoteS3SecretKeyReference: complete.secretKey
            ),
            request(
                "backup-delete",
                ids: [volume1],
                resourceID: resource,
                dryRun: true,
                remoteS3Endpoint: complete.endpoint,
                remoteS3Bucket: complete.bucket,
                remoteS3Region: complete.region,
                remoteS3Prefix: complete.prefix,
                remoteS3AccessKeyReference:
                    "external://provider/access",
                remoteS3SecretKeyReference: complete.secretKey
            ),
            request(
                "backup-delete",
                ids: [volume1],
                resourceID: resource,
                dryRun: true,
                remoteS3Endpoint: complete.endpoint,
                remoteS3Bucket: complete.bucket,
                remoteS3Region: complete.region,
                remoteS3Prefix: complete.prefix,
                remoteS3AccessKeyReference: complete.accessKey,
                remoteS3SecretKeyReference: complete.accessKey
            ),
            request(
                "backup-list",
                ids: [volume1],
                remoteS3Endpoint: complete.endpoint,
                remoteS3Bucket: complete.bucket,
                remoteS3Region: complete.region,
                remoteS3Prefix: complete.prefix,
                remoteS3AccessKeyReference: complete.accessKey,
                remoteS3SecretKeyReference: complete.secretKey
            ),
            request(
                "snapshot-list",
                ids: [volume1],
                remoteS3Endpoint: complete.endpoint,
                remoteS3Bucket: complete.bucket,
                remoteS3Region: complete.region,
                remoteS3Prefix: complete.prefix,
                remoteS3AccessKeyReference: complete.accessKey,
                remoteS3SecretKeyReference: complete.secretKey
            ),
        ]

        for request in invalid {
            XCTAssertThrowsError(
                try LocalControlRequestParser.validate(request),
                request.requestID
            )
        }
    }

    func testOneShotControlExecutesVolumeCapacityThroughSharedProvider() throws {
        let temporaryPath =
            FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath =
            temporaryPath.hasPrefix("/var/")
                ? "/private\(temporaryPath)"
                : temporaryPath
        let containerRoot = URL(
            fileURLWithPath: canonicalTemporaryPath,
            isDirectory: true
        )
            .appendingPathComponent(
                "hostwright-control-volume-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: containerRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: containerRoot)
        }
        let root = containerRoot.appendingPathComponent(
            "provider",
            isDirectory: true
        )
        let provider = try LocalStorageProvider(
            rootURL: root,
            totalCapacityBytes: 16 * 1_024 * 1_024
        )
        let environment = CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in "" },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            storageProvider: { provider },
            storageProviderRootURL: { root },
            swiftVersion: { nil },
            platformSnapshot: {
                PlatformSnapshot(
                    macOSMajorVersion: 26,
                    architecture: "arm64"
                )
            },
            operatingSystemDescription: { "test" }
        )
        let api = LocalControlAPI(
            configuration: LocalControlConfiguration(
                manifestPath: "/not-required-for-volume"
            ),
            environment: environment
        )

        let result = api.run(
            requestData: try JSONEncoder().encode(
                request("capacity")
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        let response = try JSONDecoder().decode(
            LocalControlResponse.self,
            from: result.standardOutput
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.operation, .volume)
        guard case .object(let object) = response.result else {
            return XCTFail("Expected one structured volume response.")
        }
        XCTAssertEqual(object["kind"], .string("storageCapacity"))
        XCTAssertEqual(
            object["totalCapacityBytes"],
            .integer(16 * 1_024 * 1_024)
        )
    }

    private func request(
        _ operation: String,
        ids: [String]? = nil,
        project: String? = nil,
        resourceID: String? = nil,
        name: String? = nil,
        targetVolumeID: String? = nil,
        referenceID: String? = nil,
        owner: String? = nil,
        outputPath: String? = nil,
        keyReference: String? = nil,
        restoreTargets: [String]? = nil,
        idempotencyKey: String? = nil,
        dryRun: Bool? = nil,
        confirmPlan: String? = nil,
        remoteS3Endpoint: String? = nil,
        remoteS3Bucket: String? = nil,
        remoteS3Region: String? = nil,
        remoteS3Prefix: String? = nil,
        remoteS3AccessKeyReference: String? = nil,
        remoteS3SecretKeyReference: String? = nil
    ) -> LocalControlRequest {
        LocalControlRequest(
            requestID:
                "volume-\(operation.replacingOccurrences(of: "_", with: "-"))",
            operation: .volume,
            project: project,
            dryRun: dryRun,
            confirmPlan: confirmPlan,
            volumeOperation: operation,
            volumeIDs: ids,
            volumeResourceID: resourceID,
            volumeName: name,
            volumeTargetVolumeID: targetVolumeID,
            volumeReferenceID: referenceID,
            volumeOwner: owner,
            volumeOutputPath: outputPath,
            volumeKeyReference: keyReference,
            volumeRestoreTargets: restoreTargets,
            volumeIdempotencyKey: idempotencyKey,
            volumeRemoteS3Endpoint: remoteS3Endpoint,
            volumeRemoteS3Bucket: remoteS3Bucket,
            volumeRemoteS3Region: remoteS3Region,
            volumeRemoteS3Prefix: remoteS3Prefix,
            volumeRemoteS3AccessKeyReference:
                remoteS3AccessKeyReference,
            volumeRemoteS3SecretKeyReference:
                remoteS3SecretKeyReference
        )
    }

    private func value(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

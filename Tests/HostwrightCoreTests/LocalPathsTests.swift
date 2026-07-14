import Darwin
import Foundation
import XCTest
@testable import HostwrightCore

final class LocalPathsTests: XCTestCase {
    func testDefaultLayoutUsesMacOSNativeLocations() throws {
        let resolution = try HostwrightLocalPathResolver.resolve(
            homeDirectory: "/Users/example",
            environment: [:]
        )

        XCTAssertEqual(resolution.statePathOrigin, .applicationSupportDefault)
        XCTAssertEqual(resolution.layout.applicationSupportDirectory, "/Users/example/Library/Application Support/Hostwright")
        XCTAssertEqual(resolution.layout.configurationDirectory, "/Users/example/Library/Application Support/Hostwright/config")
        XCTAssertEqual(resolution.layout.stateDatabase, "/Users/example/Library/Application Support/Hostwright/state/state.sqlite")
        XCTAssertEqual(resolution.layout.runtimeDirectory, "/Users/example/Library/Application Support/Hostwright/run")
        XCTAssertEqual(resolution.layout.metadataDirectory, "/Users/example/Library/Application Support/Hostwright/metadata")
        XCTAssertEqual(resolution.layout.backupsDirectory, "/Users/example/Library/Application Support/Hostwright/backups")
        XCTAssertEqual(resolution.layout.cacheDirectory, "/Users/example/Library/Caches/Hostwright")
        XCTAssertEqual(resolution.layout.logDirectory, "/Users/example/Library/Logs/Hostwright")
        XCTAssertEqual(resolution.legacyStateDatabase, "/Users/example/.hostwright/state.sqlite")
        XCTAssertEqual(
            resolution.legacyStateMigrationJournal,
            "/Users/example/Library/Application Support/Hostwright/metadata/legacy-state-migration.json"
        )
    }

    func testStateOverridePrecedenceIsExplicitThenEnvironmentThenDefault() throws {
        let variables = [
            HostwrightLocalPathResolver.applicationSupportOverride: "/Volumes/Safe/Support",
            HostwrightLocalPathResolver.cacheOverride: "/Volumes/Safe/Cache",
            HostwrightLocalPathResolver.logOverride: "/Volumes/Safe/Logs",
            HostwrightLocalPathResolver.stateDatabaseOverride: "/Volumes/Safe/environment.sqlite"
        ]

        let environmentResolution = try HostwrightLocalPathResolver.resolve(
            homeDirectory: "/Users/example",
            environment: variables
        )
        XCTAssertEqual(environmentResolution.statePathOrigin, .environment)
        XCTAssertEqual(environmentResolution.stateDatabasePath, "/Volumes/Safe/environment.sqlite")
        XCTAssertEqual(environmentResolution.layout.applicationSupportDirectory, "/Volumes/Safe/Support")
        XCTAssertEqual(environmentResolution.layout.cacheDirectory, "/Volumes/Safe/Cache")
        XCTAssertEqual(environmentResolution.layout.logDirectory, "/Volumes/Safe/Logs")

        let explicitResolution = try HostwrightLocalPathResolver.resolve(
            explicitStateDatabasePath: "/Volumes/Safe/explicit.sqlite",
            homeDirectory: "/Users/example",
            environment: variables
        )
        XCTAssertEqual(explicitResolution.statePathOrigin, .explicit)
        XCTAssertEqual(explicitResolution.stateDatabasePath, "/Volumes/Safe/explicit.sqlite")
    }

    func testPathResolutionRejectsRelativeTraversalAndInvalidOverrides() {
        for path in [
            "state.sqlite",
            "/Users/example/../state.sqlite",
            "/Users/example//state.sqlite",
            "/Users/example/state.sqlite/",
            "/Users/example/state\n.sqlite",
            "//server/share/state.sqlite",
            "   ",
            "/" + String(repeating: "a", count: 5_000),
            "/Users/example/" + String(repeating: "a", count: 256)
        ] {
            XCTAssertThrowsError(
                try HostwrightLocalPathResolver.resolve(
                    explicitStateDatabasePath: path,
                    homeDirectory: "/Users/example",
                    environment: [:]
                )
            )
        }
        let pathAtSystemLimit = String(repeating: "/a", count: Int(PATH_MAX) / 2)
        XCTAssertEqual(pathAtSystemLimit.utf8.count, Int(PATH_MAX))
        XCTAssertThrowsError(
            try HostwrightLocalPathResolver.normalizedAbsolutePath(
                pathAtSystemLimit,
                role: "state database"
            )
        )
        let nearLimitHome = "/" + Array(
            repeating: String(repeating: "h", count: 245),
            count: 4
        ).joined(separator: "/")
        XCTAssertLessThan(nearLimitHome.utf8.count, Int(PATH_MAX))
        XCTAssertThrowsError(
            try HostwrightLocalPathResolver.resolve(
                homeDirectory: nearLimitHome,
                environment: [:]
            )
        )
        XCTAssertThrowsError(
            try HostwrightLocalPathResolver.resolve(
                homeDirectory: "/Users/example",
                environment: [HostwrightLocalPathResolver.cacheOverride: "relative/cache"]
            )
        ) { error in
            guard case .invalidEnvironmentOverride(let name, _) = error as? HostwrightLocalPathError else {
                return XCTFail("Expected invalidEnvironmentOverride, received \(error)")
            }
            XCTAssertEqual(name, HostwrightLocalPathResolver.cacheOverride)
        }

        for name in [
            HostwrightLocalPathResolver.applicationSupportOverride,
            HostwrightLocalPathResolver.cacheOverride,
            HostwrightLocalPathResolver.logOverride,
            HostwrightLocalPathResolver.stateDatabaseOverride
        ] {
            XCTAssertThrowsError(
                try HostwrightLocalPathResolver.resolve(
                    homeDirectory: "/Users/example",
                    environment: [name: "  "]
                )
            ) { error in
                guard case .invalidEnvironmentOverride(let rejectedName, _) =
                    error as? HostwrightLocalPathError else {
                    return XCTFail("Expected invalidEnvironmentOverride, received \(error)")
                }
                XCTAssertEqual(rejectedName, name)
            }
        }
    }

    func testExplicitStateUsesStableRuntimeLockIdentity() throws {
        let resolution = try HostwrightLocalPathResolver.resolve(
            explicitStateDatabasePath: "/Users/example/state.sqlite",
            homeDirectory: "/Users/example",
            environment: [:]
        )
        let first = try resolution.daemonLockPath()
        let second = try resolution.daemonLockPath()
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("/Users/example/Library/Application Support/Hostwright/run/hostwrightd-"))
        XCTAssertTrue(first.hasSuffix(".lock"))
    }

    func testFilesystemPolicyRejectsAccessGrantingExtendedACLs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-acl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        XCTAssertEqual(chmod(file.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertNoThrow(
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                atPath: file.path,
                role: "test file"
            )
        )
        try setEveryoneReadACL(on: file.path)
        XCTAssertThrowsError(
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                atPath: file.path,
                role: "test file"
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("access-granting"))
        }

        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertThrowsError(
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: descriptor,
                path: file.path,
                role: "test file"
            )
        )
    }

    private func setEveryoneReadACL(on path: String) throws {
        let text = """
        !#acl 1
        group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read

        """
        guard let accessControlList = acl_from_text(text) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
        guard acl_set_file(path, ACL_TYPE_EXTENDED, accessControlList) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

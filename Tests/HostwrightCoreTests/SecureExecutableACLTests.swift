import Darwin
import Foundation
import HostwrightCore
import XCTest

final class SecureExecutableACLTests: XCTestCase {
    func testExecutableWithWriteGrantIsRejectedDespiteSafeMode() throws {
        try withExecutable { _, executable in
            try setACL("allow:write", on: executable)
            assertUnsafe { try SecureExecutableResolver.verify(path: executable.path) }
            assertUnsafe {
                try SecureExecutableResolver.resolve(
                    named: executable.lastPathComponent,
                    searchPath: executable.deletingLastPathComponent().path,
                    ownershipPolicy: .rootOrCurrentUser
                )
            }
        }
    }

    func testAddingWriteGrantInvalidatesPreviouslyVerifiedExecutable() throws {
        try withExecutable { _, executable in
            let identity = try SecureExecutableResolver.verify(path: executable.path)
            try setACL("allow:write", on: executable)
            XCTAssertThrowsError(try SecureExecutableResolver.verifyUnchanged(identity))
        }
    }

    func testWritableParentACLRejectsExecutableAndWorkingDirectory() throws {
        try withExecutable { directory, executable in
            try setACL("allow:write", on: directory)
            assertUnsafe { try SecureExecutableResolver.verify(path: executable.path) }
            assertUnsafe { try SecureExecutableResolver.verifyWorkingDirectory(path: directory.path) }
        }
    }

    func testLexicalSymlinkParentWithWriteGrantIsRejected() throws {
        try withExecutable { directory, executable in
            let aliases = directory.appendingPathComponent("aliases", isDirectory: true)
            try FileManager.default.createDirectory(at: aliases, withIntermediateDirectories: false)
            let alias = aliases.appendingPathComponent("tool")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
            XCTAssertNoThrow(try SecureExecutableResolver.verify(path: alias.path))
            try setACL("allow:write", on: aliases)
            assertUnsafe { try SecureExecutableResolver.verify(path: alias.path) }
        }
    }

    func testCanonicalSymlinkTargetWithWriteGrantIsRejected() throws {
        try withExecutable { directory, executable in
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
            try setACL("allow:write", on: executable)
            assertUnsafe { try SecureExecutableResolver.verify(path: alias.path) }
        }
    }

    func testDenyOnlyACLsRemainSupported() throws {
        try withExecutable { directory, executable in
            try setACL("deny:write", on: executable)
            try setACL("deny:delete", on: directory)
            defer { try? clearACL(on: directory) }
            let identity = try SecureExecutableResolver.verify(path: executable.path)
            XCTAssertNoThrow(try SecureExecutableResolver.verifyUnchanged(identity))
            XCTAssertNoThrow(try SecureExecutableResolver.verifyWorkingDirectory(path: directory.path))
        }
    }

    private func assertUnsafe<T>(
        file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? SecureExecutableValidationError, .unsafePermissions, file: file, line: line)
        }
    }

    private func withExecutable(_ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-executable-acl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("verified-tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/printf"), to: executable)
        XCTAssertEqual(chmod(executable.path, 0o755), 0)
        XCTAssertNoThrow(try SecureExecutableResolver.verify(path: executable.path))
        try body(directory, executable)
    }

    private func setACL(_ entry: String, on url: URL) throws {
        let text = "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\(entry)\n"
        guard let acl = acl_from_text(text) else { throw POSIXError(.EINVAL) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func clearACL(on url: URL) throws {
        guard let acl = acl_init(0) else { throw POSIXError(.ENOMEM) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

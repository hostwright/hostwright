import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI

final class SecretInputDescriptorTests: XCTestCase {
    func testDuplicateDoesNotConsumeInputAndRestoresSharedFlags() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let bytes: [UInt8] = [0x61, 0x00, 0x62, 0x0A]
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }, bytes.count)
        let originalFlags = fcntl(descriptors[0], F_GETFL)
        let input = try HostwrightSecretInputDescriptor(fileDescriptor: descriptors[0])
        XCTAssertNotEqual(input.descriptor, descriptors[0])
        XCTAssertNotEqual(fcntl(input.descriptor, F_GETFD) & FD_CLOEXEC, 0)
        try input.prepare()
        XCTAssertEqual(fcntl(input.descriptor, F_SETFL, originalFlags | O_NONBLOCK), 0)
        try input.restore()
        XCTAssertEqual(fcntl(descriptors[0], F_GETFL), originalFlags)
        XCTAssertEqual(fcntl(input.descriptor, F_GETFD), -1)
        var actual = [UInt8](repeating: 0, count: bytes.count)
        XCTAssertEqual(actual.withUnsafeMutableBytes { Darwin.read(descriptors[0], $0.baseAddress, $0.count) }, bytes.count)
        XCTAssertEqual(actual, bytes)
    }

    func testTerminalEchoAndFlagsRestoreAfterFailure() throws {
        var master: Int32 = -1
        var terminal: Int32 = -1
        XCTAssertEqual(openpty(&master, &terminal, nil, nil, nil), 0)
        defer { close(master); close(terminal) }
        var original = termios()
        XCTAssertEqual(tcgetattr(terminal, &original), 0)
        original.c_lflag |= tcflag_t(ECHO | ECHONL)
        XCTAssertEqual(tcsetattr(terminal, TCSANOW, &original), 0)
        let flags = fcntl(terminal, F_GETFL)
        XCTAssertThrowsError(try failWithProtectedInput(terminal, originalFlags: flags))
        var restored = termios()
        XCTAssertEqual(tcgetattr(terminal, &restored), 0)
        XCTAssertEqual(restored.c_lflag, original.c_lflag)
        XCTAssertEqual(restored.c_iflag, original.c_iflag)
        XCTAssertEqual(restored.c_oflag, original.c_oflag)
        XCTAssertEqual(restored.c_cflag, original.c_cflag)
        XCTAssertEqual(fcntl(terminal, F_GETFL), flags)
    }

    func testRejectedPreparationLeavesTerminalUnchanged() throws {
        var master: Int32 = -1
        var terminal: Int32 = -1
        XCTAssertEqual(openpty(&master, &terminal, nil, nil, nil), 0)
        defer { close(master); close(terminal) }
        var original = termios()
        XCTAssertEqual(tcgetattr(terminal, &original), 0)
        do {
            let input = try HostwrightSecretInputDescriptor(fileDescriptor: terminal)
            try input.restore()
        }
        var actual = termios()
        XCTAssertEqual(tcgetattr(terminal, &actual), 0)
        XCTAssertEqual(actual.c_lflag, original.c_lflag)
    }

    func testRestoringEchoDiscardsUnreadTerminalSecret() throws {
        var master: Int32 = -1
        var terminal: Int32 = -1
        XCTAssertEqual(openpty(&master, &terminal, nil, nil, nil), 0)
        defer { close(master); close(terminal) }
        let originalFlags = fcntl(terminal, F_GETFL)
        let input = try HostwrightSecretInputDescriptor(fileDescriptor: terminal)
        try input.prepare()
        let pending = Data("unread-secret\n".utf8)
        XCTAssertEqual(pending.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }, pending.count)
        try input.restore()
        XCTAssertEqual(fcntl(terminal, F_SETFL, originalFlags | O_NONBLOCK), 0)
        defer { _ = fcntl(terminal, F_SETFL, originalFlags) }
        var buffer = [UInt8](repeating: 0, count: pending.count)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(terminal, $0.baseAddress, $0.count) }
        let readError = errno
        XCTAssertEqual(count, -1)
        XCTAssertEqual(readError, EAGAIN)
    }

    func testWriteOnlyDescriptorIsRejected() throws {
        let descriptor = open("/dev/null", O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertThrowsError(try HostwrightSecretInputDescriptor(fileDescriptor: descriptor))
    }

    private func failWithProtectedInput(_ descriptor: Int32, originalFlags: Int32) throws {
        let input = try HostwrightSecretInputDescriptor(fileDescriptor: descriptor)
        try input.prepare()
        var protected = termios()
        XCTAssertEqual(tcgetattr(descriptor, &protected), 0)
        XCTAssertEqual(protected.c_lflag & tcflag_t(ECHO | ECHONL), 0)
        XCTAssertEqual(fcntl(input.descriptor, F_SETFL, originalFlags | O_NONBLOCK), 0)
        throw InputFailure.expected
    }
}

private enum InputFailure: Error { case expected }

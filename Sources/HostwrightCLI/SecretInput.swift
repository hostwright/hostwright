import Darwin
import Foundation
import HostwrightSecrets

public final class HostwrightSecretInputDescriptor {
    public let descriptor: Int32
    private let originalFlags: Int32
    private var originalTerminal: termios?
    private var prepared = false
    private var closed = false

    public init(fileDescriptor: Int32 = STDIN_FILENO) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE != O_WRONLY else {
            throw SecretStoreError.backendUnavailable("Secret input is not readable.")
        }
        let duplicate = fcntl(fileDescriptor, F_DUPFD_CLOEXEC, 3)
        guard duplicate >= 0 else {
            throw SecretStoreError.backendUnavailable("Unable to duplicate secret input.")
        }
        descriptor = duplicate
        originalFlags = flags
    }

    deinit { try? restore() }

    public func prepare() throws {
        guard !closed, !prepared else {
            throw SecretStoreError.backendUnavailable("Secret input is unavailable.")
        }
        if isatty(descriptor) == 1 {
            var original = termios()
            guard tcgetattr(descriptor, &original) == 0 else {
                throw SecretStoreError.backendUnavailable("Unable to inspect terminal settings for secret input.")
            }
            originalTerminal = original
            var protected = original
            protected.c_lflag &= ~tcflag_t(ECHO | ECHONL)
            guard tcsetattr(descriptor, TCSANOW, &protected) == 0 else {
                throw SecretStoreError.backendUnavailable("Unable to disable terminal echo for secret input.")
            }
            FileHandle.standardError.write(Data("Secret value: ".utf8))
        }
        prepared = true
    }

    public func restore() throws {
        guard !closed else { return }
        var restored = true
        if var originalTerminal {
            // Do not return unread secret input to the shell after refusal or cancellation.
            restored = tcsetattr(descriptor, TCSAFLUSH, &originalTerminal) == 0
            self.originalTerminal = nil
            FileHandle.standardError.write(Data("\n".utf8))
        }
        let currentFlags = fcntl(descriptor, F_GETFL)
        if currentFlags < 0 {
            restored = false
        } else if currentFlags != originalFlags {
            restored = fcntl(descriptor, F_SETFL, originalFlags) == 0 && restored
        }
        _ = Darwin.close(descriptor)
        closed = true
        guard restored else {
            throw SecretStoreError.backendUnavailable("Unable to restore secret input settings.")
        }
    }
}

enum HostwrightSecretInputReader {
    static func read() throws -> Data {
        if isatty(STDIN_FILENO) == 1 {
            return try readFromTerminal()
        }
        return try readBytes(
            fileDescriptor: STDIN_FILENO,
            stopAtNewline: false
        )
    }

    private static func readFromTerminal() throws -> Data {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw SecretStoreError.backendUnavailable(
                "Unable to inspect terminal settings for secret input."
            )
        }
        var protected = original
        protected.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &protected) == 0 else {
            throw SecretStoreError.backendUnavailable(
                "Unable to disable terminal echo for secret input."
            )
        }

        FileHandle.standardError.write(Data("Secret value: ".utf8))
        defer {
            var restore = original
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return try readBytes(
            fileDescriptor: STDIN_FILENO,
            stopAtNewline: true
        )
    }

    static func readBytes(
        fileDescriptor: Int32,
        stopAtNewline: Bool
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    fileDescriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if count == 0 {
                return result
            }
            if count < 0 {
                if errno == EINTR {
                    throw SecretStoreError.cancelled(
                        "Secret input was cancelled."
                    )
                }
                throw SecretStoreError.backendUnavailable(
                    "Unable to read secret input."
                )
            }

            let bytes = buffer.prefix(count)
            if stopAtNewline,
               let delimiter = bytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                try append(bytes[..<delimiter], to: &result)
                return result
            }
            try append(bytes[...], to: &result)
        }
    }

    private static func append<C: Collection>(
        _ bytes: C,
        to result: inout Data
    ) throws where C.Element == UInt8 {
        guard result.count <= HostwrightSecretValue.maximumByteCount - bytes.count else {
            throw SecretStoreError.invalidValue(
                "Secret values must not exceed 64 KiB."
            )
        }
        result.append(contentsOf: bytes)
    }
}

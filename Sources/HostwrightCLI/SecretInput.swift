import Darwin
import Foundation
import HostwrightSecrets

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

import Darwin
import Foundation

private func writePIDFile(_ path: String, parent: pid_t, child: pid_t) -> Bool {
    let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR) }
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    let bytes = Array("\(parent) \(child)\n".utf8)
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return false }
        offset += count
    }
    return fsync(descriptor) == 0
}

private func waitForever() -> Never {
    while true { pause() }
}

private func spawnSleepingChild() -> pid_t {
    let executable = CommandLine.arguments[0]
    var arguments: [UnsafeMutablePointer<CChar>?] = [
        strdup(executable),
        strdup("child-sleep"),
        nil
    ]
    var environment: [UnsafeMutablePointer<CChar>?] = [
        strdup("LANG=C"),
        strdup("LC_ALL=C"),
        strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"),
        nil
    ]
    defer {
        for pointer in arguments {
            if let pointer { free(pointer) }
        }
        for pointer in environment {
            if let pointer { free(pointer) }
        }
    }
    var child: pid_t = 0
    let result = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
        environment.withUnsafeMutableBufferPointer { environmentBuffer in
            posix_spawn(
                &child,
                executable,
                nil,
                nil,
                argumentBuffer.baseAddress!,
                environmentBuffer.baseAddress!
            )
        }
    }
    return result == 0 ? child : -1
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { exit(64) }

switch arguments[1] {
case "echo-stdin":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    FileHandle.standardOutput.write(input)

case "close-stdin":
    close(STDIN_FILENO)

case "flood-stderr":
    FileHandle.standardError.write(Data(repeating: 69, count: 256 * 1_024))

case "list-fds":
    let descriptors = (STDERR_FILENO + 1...2_048).filter { fcntl($0, F_GETFD) >= 0 }
    if !descriptors.isEmpty {
        FileHandle.standardOutput.write(Data(descriptors.map(String.init).joined(separator: ",").utf8))
    }

case "cwd":
    FileHandle.standardOutput.write(Data(FileManager.default.currentDirectoryPath.utf8))

case "child-sleep":
    _ = Darwin.signal(SIGTERM, SIG_IGN)
    waitForever()

case "fork-sleep", "fork-exit":
    guard arguments.count == 3 else { exit(65) }
    _ = Darwin.signal(SIGTERM, SIG_IGN)
    let child = spawnSleepingChild()
    guard child >= 0 else { exit(66) }
    guard writePIDFile(arguments[2], parent: getpid(), child: child) else {
        kill(child, SIGKILL)
        exit(67)
    }
    if arguments[1] == "fork-exit" { exit(0) }
    waitForever()

default:
    exit(68)
}

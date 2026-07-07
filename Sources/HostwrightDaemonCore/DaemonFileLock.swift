import Darwin
import Foundation

public final class FileDaemonInstanceLock: DaemonInstanceLock {
    private let path: String
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    public func acquire() throws -> Bool {
        if descriptor >= 0 {
            return true
        }

        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty && directory != path {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        let opened = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard opened >= 0 else {
            throw DaemonError.lockFailed(path: path, message: String(cString: strerror(errno)))
        }

        if flock(opened, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            Darwin.close(opened)
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                return false
            }
            throw DaemonError.lockFailed(path: path, message: String(cString: strerror(lockErrno)))
        }

        descriptor = opened
        return true
    }

    public func release() {
        guard descriptor >= 0 else {
            return
        }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

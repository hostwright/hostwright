import Foundation

public final class HostwrightCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

public enum HostwrightCancellationContext {
    @TaskLocal public static var token: HostwrightCancellationToken?
}

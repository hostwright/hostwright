import Foundation
import HostwrightCore

public struct ResolvedRuntimeExecutable: Equatable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public protocol RuntimeExecutableResolving: Sendable {
    func resolveExecutable(named name: String) throws -> ResolvedRuntimeExecutable?
}

public struct RuntimeExecutableResolver: RuntimeExecutableResolving {
    public let path: String?

    public init(path: String? = ProcessInfo.processInfo.environment["PATH"]) {
        self.path = path
    }

    public func resolveExecutable(named name: String) throws -> ResolvedRuntimeExecutable? {
        do {
            guard let executable = try SecureExecutableResolver.resolve(named: name, searchPath: path) else {
                return nil
            }
            return ResolvedRuntimeExecutable(name: name, path: executable.path)
        } catch let error as SecureExecutableValidationError {
            throw RuntimeAdapterError.permissionDenied(
                "Runtime executable resolution rejected an unsafe PATH candidate: \(error.description)"
            )
        }
    }
}

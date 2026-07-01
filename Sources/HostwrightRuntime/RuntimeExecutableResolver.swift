import Foundation

public struct ResolvedRuntimeExecutable: Equatable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public protocol RuntimeExecutableResolving: Sendable {
    func resolveExecutable(named name: String) -> ResolvedRuntimeExecutable?
}

public struct RuntimeExecutableResolver: RuntimeExecutableResolving {
    public let path: String?

    public init(path: String? = ProcessInfo.processInfo.environment["PATH"]) {
        self.path = path
    }

    public func resolveExecutable(named name: String) -> ResolvedRuntimeExecutable? {
        guard let path, !name.isEmpty, !name.contains("/") else {
            return nil
        }

        for directory in path.split(separator: ":").map(String.init) {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return ResolvedRuntimeExecutable(name: name, path: candidate)
            }
        }

        return nil
    }
}

public struct FixedRuntimeExecutableResolver: RuntimeExecutableResolving {
    public let executables: [String: String]

    public init(executables: [String: String]) {
        self.executables = executables
    }

    public func resolveExecutable(named name: String) -> ResolvedRuntimeExecutable? {
        guard let path = executables[name] else {
            return nil
        }
        return ResolvedRuntimeExecutable(name: name, path: path)
    }
}


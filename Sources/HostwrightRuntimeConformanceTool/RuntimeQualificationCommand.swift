import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime

struct RuntimeQualificationCommandResult: Sendable {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32

    static func success(_ output: String = "") -> Self {
        Self(standardOutput: output, standardError: "", exitCode: 0)
    }

    static func failure(_ message: String, exitCode: Int32) -> Self {
        Self(standardOutput: "", standardError: message + "\n", exitCode: exitCode)
    }
}

enum RuntimeQualificationCommandError: Error, Equatable {
    case usage(String)
    case blocked(String)
    case failed(String)

    var exitCode: Int32 {
        switch self {
        case .usage: 64
        case .blocked: 69
        case .failed: 70
        }
    }

    var message: String {
        switch self {
        case .usage(let value): "USAGE: \(value)"
        case .blocked(let value): "BLOCKED: \(value)"
        case .failed(let value): "FAILED: \(value)"
        }
    }
}

enum RuntimeQualificationOperation: String, Sendable {
    case conformance
    case migration
    case recovery
}

struct RuntimeQualificationOptions: Sendable {
    let operation: RuntimeQualificationOperation
    let providerID: RuntimeProviderID?
    let expectedVersion: String?
    let sourceProviderID: RuntimeProviderID?
    let targetProviderID: RuntimeProviderID?
    let expectedSourceVersion: String?
    let expectedTargetVersion: String?
    let scenario: String?
    let priorHelperURL: URL?
    let localImage: String
    let outputURL: URL
}

enum RuntimeQualificationCommand {
    static let versionLine = "hostwright-runtime-conformance \(HostwrightIdentity.version)"

    static func run(arguments: [String]) async -> RuntimeQualificationCommandResult {
        if arguments == ["--version"] {
            return .success(versionLine + "\n")
        }
        do {
            let options = try parse(arguments)
            try await RuntimeQualificationExecutor.execute(options)
            return .success("Phase 03 \(options.operation.rawValue) evidence passed: \(options.outputURL.path)\n")
        } catch let error as RuntimeQualificationCommandError {
            return .failure(error.message, exitCode: error.exitCode)
        } catch {
            return .failure("FAILED: Phase 03 qualification failed at a bounded internal boundary.", exitCode: 70)
        }
    }

    static func parse(_ arguments: [String]) throws -> RuntimeQualificationOptions {
        guard let first = arguments.first,
              let operation = RuntimeQualificationOperation(rawValue: first) else {
            throw RuntimeQualificationCommandError.usage(
                "expected conformance, migration, recovery, or --version."
            )
        }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw RuntimeQualificationCommandError.usage("\(key) requires one value.")
            }
            let value = arguments[index + 1]
            guard !value.isEmpty, !value.hasPrefix("--"), values[key] == nil else {
                throw RuntimeQualificationCommandError.usage("invalid or duplicate option \(key).")
            }
            try validateScalar(value, name: key, maximumBytes: key == "--local-image" ? 512 : 1_024)
            values[key] = value
            index += 2
        }

        let allowed: Set<String>
        switch operation {
        case .conformance:
            allowed = ["--provider", "--expected-version", "--local-image", "--output"]
        case .migration:
            allowed = [
                "--source-provider", "--target-provider", "--expected-source-version",
                "--expected-target-version", "--local-image", "--output"
            ]
        case .recovery:
            let base: Set<String> = [
                "--provider", "--expected-version", "--scenario", "--local-image", "--output"
            ]
            allowed = values["--scenario"] == "stale-helper"
                ? base.union(["--prior-helper"])
                : base
        }
        guard Set(values.keys) == allowed else {
            throw RuntimeQualificationCommandError.usage(
                "\(operation.rawValue) received missing or unsupported options."
            )
        }

        let localImage = try required("--local-image", in: values)
        let outputURL = try validatedOutputURL(try required("--output", in: values))
        switch operation {
        case .conformance:
            let providerID = try provider(try required("--provider", in: values))
            let expectedVersion = try supportedVersion(
                try required("--expected-version", in: values),
                providerID: providerID
            )
            return RuntimeQualificationOptions(
                operation: operation,
                providerID: providerID,
                expectedVersion: expectedVersion,
                sourceProviderID: nil,
                targetProviderID: nil,
                expectedSourceVersion: nil,
                expectedTargetVersion: nil,
                scenario: nil,
                priorHelperURL: nil,
                localImage: localImage,
                outputURL: outputURL
            )
        case .migration:
            let source = try provider(try required("--source-provider", in: values))
            let target = try provider(try required("--target-provider", in: values))
            guard source != target else {
                throw RuntimeQualificationCommandError.usage("migration providers must differ.")
            }
            return RuntimeQualificationOptions(
                operation: operation,
                providerID: nil,
                expectedVersion: nil,
                sourceProviderID: source,
                targetProviderID: target,
                expectedSourceVersion: try supportedVersion(
                    try required("--expected-source-version", in: values), providerID: source
                ),
                expectedTargetVersion: try supportedVersion(
                    try required("--expected-target-version", in: values), providerID: target
                ),
                scenario: nil,
                priorHelperURL: nil,
                localImage: localImage,
                outputURL: outputURL
            )
        case .recovery:
            let providerID = try provider(try required("--provider", in: values))
            let expectedVersion = try supportedVersion(
                try required("--expected-version", in: values), providerID: providerID
            )
            let scenario = try required("--scenario", in: values)
            let allowedScenarios: Set<String> = [
                "cli-service-restart", "helper-restart", "hostwright-termination",
                "mixed-component-versions", "checkpoint-crash", "stale-helper",
                "future-protocol-refusal", "downgrade-refusal"
            ]
            guard allowedScenarios.contains(scenario),
                  scenario != "cli-service-restart" || providerID == .appleContainerCLI,
                  !["helper-restart", "stale-helper"].contains(scenario) || providerID == .appleContainerization else {
                throw RuntimeQualificationCommandError.usage("recovery scenario does not match the provider.")
            }
            let priorHelperURL = scenario == "stale-helper"
                ? try validatedPriorHelperURL(try required("--prior-helper", in: values))
                : nil
            return RuntimeQualificationOptions(
                operation: operation,
                providerID: providerID,
                expectedVersion: expectedVersion,
                sourceProviderID: nil,
                targetProviderID: nil,
                expectedSourceVersion: nil,
                expectedTargetVersion: nil,
                scenario: scenario,
                priorHelperURL: priorHelperURL,
                localImage: localImage,
                outputURL: outputURL
            )
        }
    }

    private static func required(_ name: String, in values: [String: String]) throws -> String {
        guard let value = values[name] else {
            throw RuntimeQualificationCommandError.usage("\(name) is required.")
        }
        return value
    }

    private static func provider(_ value: String) throws -> RuntimeProviderID {
        let providerID = RuntimeProviderID(rawValue: value)
        guard RuntimeProviderID.knownValues.contains(providerID) else {
            throw RuntimeQualificationCommandError.usage("unsupported provider \(value).")
        }
        return providerID
    }

    private static func supportedVersion(
        _ value: String,
        providerID: RuntimeProviderID
    ) throws -> String {
        let supported: Set<String> = providerID == .appleContainerCLI
            ? ["1.0.0", "1.1.0"]
            : [ContainerizationRuntimeAssetContract.frameworkVersion]
        guard supported.contains(value) else {
            throw RuntimeQualificationCommandError.usage(
                "unsupported version \(value) for \(providerID.rawValue)."
            )
        }
        return value
    }

    private static func validateScalar(
        _ value: String,
        name: String,
        maximumBytes: Int
    ) throws {
        guard !value.hasPrefix("-"),
              !value.contains("\0"),
              value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw RuntimeQualificationCommandError.usage("\(name) contains an unsafe value.")
        }
    }

    private static func validatedOutputURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), path.hasSuffix(".json"), path.utf8.count <= 1_024 else {
            throw RuntimeQualificationCommandError.usage("--output must be an absolute .json path.")
        }
        let normalized = NSString(string: path).standardizingPath
        guard normalized == path else {
            throw RuntimeQualificationCommandError.usage("--output must be normalized.")
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        var parentMetadata = stat()
        var outputMetadata = stat()
        errno = 0
        let outputStatus = lstat(path, &outputMetadata)
        let outputError = errno
        guard lstat(parent.path, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR,
              outputStatus == -1,
              outputError == ENOENT else {
            throw RuntimeQualificationCommandError.usage(
                "--output parent must be an existing directory and output must be new."
            )
        }
        return url
    }

    private static func validatedPriorHelperURL(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path.utf8.count <= 1_024,
              !path.contains("\0"),
              components.count > 1,
              components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              URL(fileURLWithPath: path).lastPathComponent ==
                "hostwright-containerization-helper" else {
            throw RuntimeQualificationCommandError.usage(
                "--prior-helper must be a normalized absolute helper executable path."
            )
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == 0 || metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISTXT) == 0,
              metadata.st_mode & S_IXUSR != 0,
              access(path, X_OK) == 0 else {
            throw RuntimeQualificationCommandError.usage(
                "--prior-helper must be a private regular executable."
            )
        }
        do {
            let identity = try SecureExecutableResolver.verify(
                path: path,
                ownershipPolicy: .rootOrCurrentUser
            )
            guard identity.path == path else {
                throw RuntimeQualificationCommandError.usage(
                    "--prior-helper may not traverse a symbolic link."
                )
            }
        } catch let error as RuntimeQualificationCommandError {
            throw error
        } catch {
            throw RuntimeQualificationCommandError.usage(
                "--prior-helper failed secure executable validation."
            )
        }
        return URL(fileURLWithPath: path)
    }
}

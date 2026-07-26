import Darwin
import Foundation

public enum StorageProviderHelperCommandError:
    Error,
    Equatable,
    Sendable
{
    case invalidArguments
    case unsupportedProvider
    case invalidRuntimeDirectory
    case invalidProviderRoot
    case overlappingDirectories
    case invalidCapacity
}

public struct StorageProviderHelperRunConfiguration:
    Equatable,
    Sendable
{
    public let runtimeDirectoryURL: URL
    public let providerRootURL: URL
    public let capacityBytes: Int64

    public init(
        runtimeDirectoryURL: URL,
        providerRootURL: URL,
        capacityBytes: Int64
    ) throws {
        guard Self.validAbsoluteNormalizedPath(
            runtimeDirectoryURL.path
        ),
        runtimeDirectoryURL.path.utf8.count <
            MemoryLayout.size(ofValue: sockaddr_un().sun_path) -
            StorageProviderRuntimeDirectory.socketName.utf8.count - 1 else {
            throw StorageProviderHelperCommandError.invalidRuntimeDirectory
        }
        guard Self.validAbsoluteNormalizedPath(providerRootURL.path) else {
            throw StorageProviderHelperCommandError.invalidProviderRoot
        }
        guard !Self.contains(
            runtimeDirectoryURL.path,
            providerRootURL.path
        ),
        !Self.contains(
            providerRootURL.path,
            runtimeDirectoryURL.path
        ) else {
            throw StorageProviderHelperCommandError.overlappingDirectories
        }
        guard capacityBytes > 0,
              capacityBytes <=
                StorageSemanticLimits.maximumCapacityBytes else {
            throw StorageProviderHelperCommandError.invalidCapacity
        }
        self.runtimeDirectoryURL = runtimeDirectoryURL
        self.providerRootURL = providerRootURL
        self.capacityBytes = capacityBytes
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent + "/")
    }

    static func validAbsoluteNormalizedPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"),
              value != "/",
              value.utf8.count <= Int(PATH_MAX),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.first?.isEmpty == true &&
            components.dropFirst().allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

public enum StorageProviderHelperCommand: Equatable, Sendable {
    case version
    case run(StorageProviderHelperRunConfiguration)

    public static func parse(
        arguments: [String]
    ) throws -> StorageProviderHelperCommand {
        if arguments == ["--version"] {
            return .version
        }
        guard arguments.count == 9,
              arguments.first == "run" else {
            throw StorageProviderHelperCommandError.invalidArguments
        }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard [
                "--provider",
                "--runtime-dir",
                "--provider-root",
                "--capacity-bytes"
            ].contains(flag),
            values[flag] == nil,
            index + 1 < arguments.count else {
                throw StorageProviderHelperCommandError.invalidArguments
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard values["--provider"] ==
                LocalStorageProviderContract.providerID else {
            throw StorageProviderHelperCommandError.unsupportedProvider
        }
        guard let runtimePath = values["--runtime-dir"],
              let providerPath = values["--provider-root"],
              let capacityText = values["--capacity-bytes"],
              StorageProviderHelperRunConfiguration
                .validAbsoluteNormalizedPath(runtimePath),
              StorageProviderHelperRunConfiguration
                .validAbsoluteNormalizedPath(providerPath),
              capacityText.range(
                  of: "^[1-9][0-9]*$",
                  options: .regularExpression
              ) != nil,
              let capacityBytes = Int64(capacityText) else {
            throw StorageProviderHelperCommandError.invalidArguments
        }
        return .run(
            try StorageProviderHelperRunConfiguration(
                runtimeDirectoryURL: URL(
                    fileURLWithPath: runtimePath,
                    isDirectory: true
                ),
                providerRootURL: URL(
                    fileURLWithPath: providerPath,
                    isDirectory: true
                ),
                capacityBytes: capacityBytes
            )
        )
    }

    public static var versionText: String {
        "\(LocalStorageProviderContract.providerVersion)\n"
    }
}

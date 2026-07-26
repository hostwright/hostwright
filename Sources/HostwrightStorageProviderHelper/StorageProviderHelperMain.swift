import Darwin
import Foundation
import HostwrightStorage
import HostwrightStorageHelper

@main
struct HostwrightStorageProviderHelperMain {
    static func main() async {
        do {
            switch try StorageProviderHelperCommand.parse(
                arguments: Array(CommandLine.arguments.dropFirst())
            ) {
            case .version:
                FileHandle.standardOutput.write(
                    Data(StorageProviderHelperCommand.versionText.utf8)
                )
            case let .run(configuration):
                let provider = try LocalStorageProvider(
                    rootURL: configuration.providerRootURL,
                    totalCapacityBytes: configuration.capacityBytes
                )
                try await StorageProviderHelperExecutable.run(
                    provider: provider,
                    runtimeDirectoryURL:
                        configuration.runtimeDirectoryURL
                )
            }
        } catch {
            FileHandle.standardError.write(
                Data(
                    "hostwright-storage-helper: startup failed\n"
                        .utf8
                )
            )
            Darwin.exit(EX_CONFIG)
        }
    }
}

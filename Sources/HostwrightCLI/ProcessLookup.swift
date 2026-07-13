import Foundation
import HostwrightCore

public enum ProcessLookup {
    public static func executablePath(named name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        try? SecureExecutableResolver.resolve(named: name, searchPath: path)?.path
    }

    public static func swiftVersionSummary() -> String? {
        guard let swiftPath = executablePath(named: "swift") else { return nil }

        do {
            let result = try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: swiftPath,
                    arguments: ["--version"],
                    environment: SecureSubprocessEnvironment.currentUser,
                    timeoutMilliseconds: 5_000,
                    maximumStandardOutputBytes: 64 * 1_024,
                    maximumStandardErrorBytes: 64 * 1_024
                )
            )
            guard result.exitStatus == 0,
                  let output = String(data: result.standardOutput, encoding: .utf8) else {
                return nil
            }
            return output.split(separator: "\n").first.map(String.init)
        } catch {
            return nil
        }
    }
}

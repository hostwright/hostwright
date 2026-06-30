import Foundation

public enum ProcessLookup {
    public static func executablePath(named name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        guard let path, !name.contains("/") else { return nil }

        for directory in path.split(separator: ":").map(String.init) {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    public static func swiftVersionSummary() -> String? {
        guard let swiftPath = executablePath(named: "swift") else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .first
            .map(String.init)

        return output
    }
}


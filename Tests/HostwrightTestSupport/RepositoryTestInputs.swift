import Foundation

public enum RepositoryTestInputs {
    public static func trackedFiles(in root: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "-z"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    public static func exampleManifests(in root: URL) throws -> [URL] {
        try trackedFiles(in: root).filter {
            let parts = $0.split(separator: "/")
            return parts.count == 3 && parts[0] == "examples" && parts[2] == "hostwright.yaml"
        }.map { root.appendingPathComponent($0) }
    }
}

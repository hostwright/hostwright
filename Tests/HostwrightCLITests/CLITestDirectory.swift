import Foundation

func withCLITestDirectory(prefix: String, _ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

func withCLITestDatabase(prefix: String, _ body: (String) throws -> Void) throws {
    try withCLITestDirectory(prefix: prefix) { directory in
        try body(directory.appendingPathComponent("state.sqlite").path)
    }
}

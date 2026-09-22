import Foundation
@testable import HostwrightState

func withTemporaryStateStore(
    prefix: String,
    throughVersion: Int,
    _ body: (SQLiteStateStore, URL) throws -> Void
) throws {
    let directory = try makeStateTestDirectory(prefix: prefix)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
    try MigrationRunner().apply(to: store, throughVersion: throughVersion)
    try body(store, directory)
}

func withTemporaryStateStore(
    prefix: String,
    throughVersion: Int,
    _ body: (SQLiteStateStore, URL) async throws -> Void
) async throws {
    let directory = try makeStateTestDirectory(prefix: prefix)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
    try MigrationRunner().apply(to: store, throughVersion: throughVersion)
    try await body(store, directory)
}

private func makeStateTestDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return directory
}

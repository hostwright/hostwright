import Darwin
import Foundation
import Synchronization
import XCTest
@testable import HostwrightState

final class SQLiteHardeningTests: XCTestCase {
    func testAuthoritativeAndPortableProfilesEnforceRealSQLitePolicy() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()

            let authoritative = try SQLiteConnection(
                path: databaseURL.path,
                createIfNeeded: false,
                profile: .authoritativeState
            )
            let policy = try authoritative.policyReport()
            XCTAssertEqual(policy.profile, .authoritativeState)
            XCTAssertEqual(policy.journalMode, "wal")
            XCTAssertEqual(policy.synchronous, 2)
            XCTAssertTrue(policy.foreignKeys)
            XCTAssertFalse(policy.trustedSchema)
            XCTAssertTrue(policy.defensive)
            XCTAssertTrue(policy.fullFSync)
            XCTAssertTrue(policy.checkpointFullFSync)
            XCTAssertEqual(policy.secureDelete, 1)
            XCTAssertTrue(policy.cellSizeCheck)
            XCTAssertFalse(policy.queryOnly)
            XCTAssertEqual(policy.tempStore, 2)
            XCTAssertEqual(policy.memoryMappedBytes, 0)
            XCTAssertEqual(policy.busyTimeoutMilliseconds, SQLiteConnection.busyTimeoutMilliseconds)
            XCTAssertTrue(policy.noFollow)

            let integrity = StateIntegrityService(store: store).inspect()
            let connectionPolicy = try XCTUnwrap(
                integrity.checks.first { $0.identifier == "sqlite.connection-policy" }
            )
            XCTAssertEqual(connectionPolicy.status, .passed)
            XCTAssertTrue(connectionPolicy.message.contains(policy.libraryVersion))
            let applicationIdentity = try XCTUnwrap(
                integrity.checks.first { $0.identifier == "hostwright.application-identity" }
            )
            XCTAssertEqual(applicationIdentity.status, .passed)
            XCTAssertTrue(applicationIdentity.message.contains("Hostwright"))

            try authoritative.execute(
                "CREATE TABLE IF NOT EXISTS policy_probe (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"
            )
            try authoritative.run(
                "INSERT INTO policy_probe (id, value) VALUES (1, ?)",
                bindings: [.text("durable")]
            )
            XCTAssertNotEqual(
                try authoritative.query("PRAGMA journal_mode = OFF").first?.first??.lowercased(),
                "off"
            )
            try authoritative.execute("PRAGMA writable_schema = ON")
            XCTAssertEqual(try authoritative.query("PRAGMA writable_schema").first?.first ?? nil, "0")
            XCTAssertThrowsError(try authoritative.query("SELECT \"missing_identifier\""))
            XCTAssertThrowsError(try authoritative.execute("ATTACH DATABASE ':memory:' AS auxiliary"))

            XCTAssertEqual(try permissions(databaseURL.path), 0o600)
            for suffix in ["-wal", "-shm"] {
                let sidecar = databaseURL.path + suffix
                XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar))
                XCTAssertEqual(try permissions(sidecar), 0o600)
            }
            try authoritative.close()

            let portable = try SQLiteConnection(
                path: databaseURL.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            let portablePolicy = try portable.policyReport()
            XCTAssertEqual(portablePolicy.profile, .portableArtifact)
            XCTAssertEqual(portablePolicy.journalMode, "delete")
            XCTAssertEqual(portablePolicy.synchronous, 3)
            try portable.close()
            XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
            if FileManager.default.fileExists(atPath: databaseURL.path + "-shm") {
                XCTAssertEqual(try permissions(databaseURL.path + "-shm"), 0o600)
            }
        }
    }

    func testManagedTransactionsRejectNestedAndEmbeddedControlWithoutCommitting() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let connection = try SQLiteConnection(
                path: databaseURL.path,
                createIfNeeded: false,
                profile: .authoritativeState
            )
            defer { try? connection.close() }
            try connection.execute(
                "CREATE TABLE transaction_probe (id TEXT PRIMARY KEY, value TEXT NOT NULL)"
            )

            XCTAssertThrowsError(try connection.transaction {
                try connection.run(
                    "INSERT INTO transaction_probe (id, value) VALUES ('nested-before', 'value')"
                )
                try connection.transaction {
                    try connection.run(
                        "INSERT INTO transaction_probe (id, value) VALUES ('nested-inner', 'value')"
                    )
                }
            }) { error in
                assertTransactionInvariant(error)
            }
            XCTAssertEqual(try rowCount("transaction_probe", connection: connection), 0)

            XCTAssertThrowsError(try connection.transaction {
                try connection.execute(
                    "INSERT INTO transaction_probe (id, value) VALUES ('embedded-commit', 'value'); /* boundary */ COMMIT"
                )
            }) { error in
                assertTransactionInvariant(error)
            }
            XCTAssertEqual(try rowCount("transaction_probe", connection: connection), 0)

            XCTAssertThrowsError(try connection.transaction {
                try connection.execute("SELECT 1; SAVEPOINT injected")
            }) { error in
                assertTransactionInvariant(error)
            }
            XCTAssertEqual(try rowCount("transaction_probe", connection: connection), 0)

            try connection.execute("BEGIN IMMEDIATE TRANSACTION")
            XCTAssertThrowsError(try connection.transaction {
                try connection.run(
                    "INSERT INTO transaction_probe (id, value) VALUES ('managed-inside-external', 'value')"
                )
            }) { error in
                assertTransactionInvariant(error)
            }
            try connection.run(
                "INSERT INTO transaction_probe (id, value) VALUES ('external-owner', 'value')"
            )
            try connection.execute("COMMIT")
            XCTAssertEqual(
                try connection.query("SELECT id FROM transaction_probe ORDER BY id").compactMap { $0[0] },
                ["external-owner"]
            )
        }
    }

    func testCancellationAndStoragePressureRollBackAndLeaveConnectionUsable() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let connection = try SQLiteConnection(
                path: databaseURL.path,
                createIfNeeded: false,
                profile: .authoritativeState
            )
            defer { try? connection.close() }
            try connection.execute(
                "CREATE TABLE pressure_probe (id TEXT PRIMARY KEY, payload BLOB NOT NULL)"
            )

            var cancellationRequested = false
            XCTAssertThrowsError(try connection.transaction(shouldCancel: { cancellationRequested }) {
                try connection.run(
                    "INSERT INTO pressure_probe (id, payload) VALUES ('cancelled', zeroblob(1024))"
                )
                cancellationRequested = true
            }) { error in
                XCTAssertEqual(error as? StateStoreError, .operationCancelled(path: databaseURL.path))
            }
            XCTAssertEqual(try rowCount("pressure_probe", connection: connection), 0)

            let pageCount = try requiredInt("PRAGMA page_count", connection: connection)
            try connection.execute("PRAGMA max_page_count = \(pageCount + 1)")
            XCTAssertThrowsError(try connection.transaction {
                try connection.run(
                    "INSERT INTO pressure_probe (id, payload) VALUES ('too-large', zeroblob(1048576))"
                )
            }) { error in
                guard case .storageFull(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected storageFull, got \(error)")
                }
                XCTAssertEqual(path, databaseURL.path)
                XCTAssertFalse(message.isEmpty)
            }
            XCTAssertEqual(try rowCount("pressure_probe", connection: connection), 0)

            try connection.execute("PRAGMA max_page_count = 2147483646")
            try connection.run(
                "INSERT INTO pressure_probe (id, payload) VALUES ('after-pressure', zeroblob(64))"
            )
            XCTAssertEqual(try rowCount("pressure_probe", connection: connection), 1)
        }
    }

    func testApplicationIdentityClaimsLegacyStateAndRejectsForeignStateBeforeMutation() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            try store.events.append([event(id: "identity-authority")])

            let legacy = try SQLiteConnection(
                path: databaseURL.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try legacy.execute("PRAGMA application_id = 0")
            try legacy.close()
            XCTAssertEqual(try applicationID(in: databaseURL), 0)

            try store.migrate()
            XCTAssertEqual(try applicationID(in: databaseURL), MigrationRunner.applicationID)
            XCTAssertEqual(try store.events.loadAll().map(\.id), ["identity-authority"])

            let foreignID = 0x0BAD_F00D
            let foreign = try SQLiteConnection(
                path: databaseURL.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try foreign.execute("PRAGMA application_id = \(foreignID)")
            try foreign.close()
            let before = try StateMaintenanceFileSupport.fingerprint(databaseURL.path)
            let sidecarsBefore = try sidecarFingerprints(databasePath: databaseURL.path)

            XCTAssertThrowsError(try store.migrate()) { error in
                guard case .incompatibleSchema(_, let latest, let message) = error as? StateStoreError else {
                    return XCTFail("Expected incompatibleSchema, got \(error)")
                }
                XCTAssertEqual(latest, MigrationRunner.latestSchemaVersion)
                XCTAssertTrue(message.contains("application_id"))
            }
            XCTAssertEqual(try StateMaintenanceFileSupport.fingerprint(databaseURL.path), before)
            XCTAssertEqual(try applicationID(in: databaseURL), foreignID)
            XCTAssertEqual(try sidecarFingerprints(databasePath: databaseURL.path), sidecarsBefore)
        }
    }

    func testFutureDeleteModeSchemaIsRefusedBeforeAnyPersistentWriteConfiguration() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let futureVersion = MigrationRunner.latestSchemaVersion + 1
            let portable = try SQLiteConnection(
                path: databaseURL.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try portable.run(
                """
                INSERT INTO schema_migrations (version, description, checksum, applied_at)
                VALUES (?, 'future schema', 'future-checksum', '2026-07-15T00:00:00Z')
                """,
                bindings: [.int(futureVersion)]
            )
            try portable.close()

            XCTAssertEqual(try journalMode(databaseURL.path), "delete")
            let bytesBefore = try Data(contentsOf: databaseURL)
            let fingerprintBefore = try StateMaintenanceFileSupport.fingerprint(databaseURL.path)
            let sidecarsBefore = try sidecarFingerprints(databasePath: databaseURL.path)
            let filesBefore = try FileManager.default.contentsOfDirectory(
                atPath: databaseURL.deletingLastPathComponent().path
            ).sorted()

            for action in [
                { try store.migrate() },
                { try store.events.append([self.event(id: "future-schema-write")]) }
            ] {
                XCTAssertThrowsError(try action()) { error in
                    guard case .incompatibleSchema(let found, let latest, let message) = error as? StateStoreError else {
                        return XCTFail("Expected incompatibleSchema, got \(error)")
                    }
                    XCTAssertEqual(found, futureVersion)
                    XCTAssertEqual(latest, MigrationRunner.latestSchemaVersion)
                    XCTAssertTrue(message.contains("newer Hostwright release"))
                }
                XCTAssertEqual(try Data(contentsOf: databaseURL), bytesBefore)
                XCTAssertEqual(
                    try StateMaintenanceFileSupport.fingerprint(databaseURL.path),
                    fingerprintBefore
                )
                XCTAssertEqual(
                    try sidecarFingerprints(databasePath: databaseURL.path),
                    sidecarsBefore
                )
                XCTAssertEqual(try journalMode(databaseURL.path), "delete")
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        atPath: databaseURL.deletingLastPathComponent().path
                    ).sorted(),
                    filesBefore
                )
            }
        }
    }

    func testFinalSymlinksAndUnsafeSQLiteSidecarsAreRejectedWithoutMutatingTargets() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let portable = try SQLiteConnection(
                path: databaseURL.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try portable.close()

            let alias = databaseURL.deletingLastPathComponent().appendingPathComponent("state-alias.sqlite")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: databaseURL)
            let databaseBefore = try StateMaintenanceFileSupport.fingerprint(databaseURL.path)
            XCTAssertThrowsError(
                try SQLiteConnection(path: alias.path, createIfNeeded: false, readOnly: true)
            ) { error in
                guard case .pathPolicyViolation(let path, _) = error as? StateStoreError else {
                    return XCTFail("Expected pathPolicyViolation, got \(error)")
                }
                XCTAssertEqual(path, alias.path)
            }
            XCTAssertEqual(try StateMaintenanceFileSupport.fingerprint(databaseURL.path), databaseBefore)
            try FileManager.default.removeItem(at: alias)

            let sentinel = databaseURL.deletingLastPathComponent().appendingPathComponent("sentinel")
            try Data("sentinel-authority".utf8).write(to: sentinel)
            XCTAssertEqual(chmod(sentinel.path, 0o600), 0)
            let sentinelBefore = try Data(contentsOf: sentinel)
            let wal = databaseURL.path + "-wal"

            try FileManager.default.createSymbolicLink(
                atPath: wal,
                withDestinationPath: sentinel.path
            )
            assertPathPolicyFailure(tryResult: { try store.validateSchema() }, expectedPath: wal)
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBefore)
            try FileManager.default.removeItem(atPath: wal)

            try Data().write(to: URL(fileURLWithPath: wal))
            XCTAssertEqual(chmod(wal, 0o644), 0)
            assertPathPolicyFailure(tryResult: { try store.validateSchema() }, expectedPath: wal)
            XCTAssertEqual(try permissions(wal), 0o644)
            try FileManager.default.removeItem(atPath: wal)

            let hardLinkSource = databaseURL.deletingLastPathComponent().appendingPathComponent("sidecar-source")
            try Data().write(to: hardLinkSource)
            XCTAssertEqual(chmod(hardLinkSource.path, 0o600), 0)
            XCTAssertEqual(link(hardLinkSource.path, wal), 0)
            assertPathPolicyFailure(tryResult: { try store.validateSchema() }, expectedPath: wal)
            XCTAssertTrue(FileManager.default.fileExists(atPath: hardLinkSource.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: wal))
        }
    }

    func testConcurrentSymlinkSwapsNeverRedirectSQLiteAccess() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let portable = try SQLiteConnection(
                path: databaseURL.path,
                createIfNeeded: false,
                profile: .portableArtifact
            )
            try portable.close()
            for suffix in ["-wal", "-shm"] {
                let sidecar = databaseURL.path + suffix
                if FileManager.default.fileExists(atPath: sidecar) {
                    try StateMaintenanceFileSupport.unlinkSensitiveFile(sidecar)
                }
            }

            let holdingPath = databaseURL.path + ".held"
            let sentinel = databaseURL.deletingLastPathComponent().appendingPathComponent("swap-sentinel")
            try Data("unmanaged-sentinel-authority".utf8).write(to: sentinel)
            XCTAssertEqual(chmod(sentinel.path, 0o600), 0)
            let sentinelBefore = try Data(contentsOf: sentinel)
            let firstSwap = expectation(description: "first symlink swap installed")
            let attackerFinished = expectation(description: "symlink swap loop finished")
            let attackerFailure = Mutex<String?>(nil)

            DispatchQueue.global(qos: .userInitiated).async {
                for iteration in 0..<1_000 {
                    guard rename(databaseURL.path, holdingPath) == 0 else {
                        attackerFailure.withLock {
                            $0 = "could not displace the database at iteration \(iteration): \(String(cString: strerror(errno)))"
                        }
                        break
                    }
                    guard symlink(sentinel.path, databaseURL.path) == 0 else {
                        let code = errno
                        _ = rename(holdingPath, databaseURL.path)
                        attackerFailure.withLock {
                            $0 = "could not install the symlink at iteration \(iteration): \(String(cString: strerror(code)))"
                        }
                        break
                    }
                    if iteration == 0 { firstSwap.fulfill() }
                    usleep(200)
                    guard unlink(databaseURL.path) == 0,
                          rename(holdingPath, databaseURL.path) == 0 else {
                        attackerFailure.withLock {
                            $0 = "could not restore the authoritative database at iteration \(iteration): \(String(cString: strerror(errno)))"
                        }
                        break
                    }
                }
                var holdingMetadata = stat()
                if lstat(holdingPath, &holdingMetadata) == 0 {
                    var databaseMetadata = stat()
                    if lstat(databaseURL.path, &databaseMetadata) == 0 {
                        _ = unlink(databaseURL.path)
                    }
                    _ = rename(holdingPath, databaseURL.path)
                }
                attackerFinished.fulfill()
            }

            wait(for: [firstSwap], timeout: 2)
            var successes = 0
            var safeRejections = 0
            var unexpected: [String] = []
            for _ in 0..<500 {
                do {
                    try store.validateSchema()
                    successes += 1
                } catch let error as StateStoreError {
                    switch error {
                    case .pathPolicyViolation, .openFailed, .ioFailure:
                        safeRejections += 1
                    default:
                        unexpected.append(String(describing: error))
                    }
                } catch {
                    unexpected.append(String(describing: error))
                }
            }
            wait(for: [attackerFinished], timeout: 5)

            XCTAssertNil(attackerFailure.withLock { $0 })
            XCTAssertGreaterThan(safeRejections, 0)
            XCTAssertGreaterThan(successes + safeRejections, 0)
            XCTAssertEqual(unexpected, [])
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBefore)
            try store.validateSchema()
            XCTAssertEqual(try store.schemaVersion(), MigrationRunner.latestSchemaVersion)
        }
    }

    func testWriterFenceSerializesWritersWhileAllowingReaders() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()
            let coordinator = StateAccessCoordinator(configuration: store.configuration)
            let acquired = expectation(description: "writer fence acquired")
            let finished = expectation(description: "writer fence released")
            let release = DispatchSemaphore(value: 0)
            let backgroundFailure = Mutex<String?>(nil)

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try coordinator.withLock(.write) {
                        acquired.fulfill()
                        guard release.wait(timeout: .now() + 5) == .success else {
                            throw StateStoreError.databaseLocked(
                                path: databaseURL.path,
                                message: "the test writer release deadline expired"
                            )
                        }
                    }
                } catch {
                    backgroundFailure.withLock { $0 = String(describing: error) }
                }
                finished.fulfill()
            }

            wait(for: [acquired], timeout: 2)
            let readStarted = ContinuousClock.now
            try coordinator.withLock(.shared) {}
            XCTAssertLessThan(readStarted.duration(to: .now), .milliseconds(200))

            let writeStarted = ContinuousClock.now
            XCTAssertThrowsError(try coordinator.withLock(.write) {}) { error in
                guard case .databaseLocked(let path, let message) = error as? StateStoreError else {
                    return XCTFail("Expected databaseLocked, got \(error)")
                }
                XCTAssertEqual(path, databaseURL.path)
                XCTAssertTrue(message.contains("state-writer fence"))
            }
            let writeWait = writeStarted.duration(to: .now)
            XCTAssertGreaterThanOrEqual(writeWait, .milliseconds(200))
            XCTAssertLessThan(writeWait, .seconds(1))

            release.signal()
            wait(for: [finished], timeout: 2)
            XCTAssertNil(backgroundFailure.withLock { $0 })
            try store.events.append([event(id: "writer-after-release")])
            XCTAssertEqual(try store.events.loadAll().map(\.id), ["writer-after-release"])
        }
    }

    func testRealProcessKillDiscardsUncommittedWALAndPreservesCommittedWAL() throws {
        try withTemporaryStore { store, databaseURL in
            try store.migrate()

            try killSQLiteSession(
                databasePath: databaseURL.path,
                script: """
                .timeout 1000
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                BEGIN IMMEDIATE;
                \(insertEventSQL(id: "process-uncommitted"));
                .print transaction-open
                """,
                marker: "transaction-open"
            )
            try store.validateSchema()
            XCTAssertFalse(try store.events.loadAll().contains { $0.id == "process-uncommitted" })
            XCTAssertEqual(StateIntegrityService(store: store).inspect().health, .healthy)

            try killSQLiteSession(
                databasePath: databaseURL.path,
                script: """
                .timeout 1000
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                BEGIN IMMEDIATE;
                \(insertEventSQL(id: "process-committed"));
                COMMIT;
                .print transaction-committed
                """,
                marker: "transaction-committed"
            )
            try store.validateSchema()
            XCTAssertTrue(try store.events.loadAll().contains { $0.id == "process-committed" })
            XCTAssertEqual(StateIntegrityService(store: store).inspect().health, .healthy)
        }
    }

    private func withTemporaryStore(
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-sqlite-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        try body(SQLiteStateStore(path: databaseURL.path), databaseURL)
    }

    private func permissions(_ path: String) throws -> mode_t {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return metadata.st_mode & 0o7777
    }

    private func requiredInt(_ sql: String, connection: SQLiteConnection) throws -> Int {
        let value = try XCTUnwrap(try connection.query(sql).first?.first ?? nil)
        return try XCTUnwrap(Int(value))
    }

    private func rowCount(_ table: String, connection: SQLiteConnection) throws -> Int {
        try requiredInt("SELECT COUNT(*) FROM \(table)", connection: connection)
    }

    private func applicationID(in databaseURL: URL) throws -> Int {
        let data = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        guard data.count >= 72 else {
            throw StateStoreError.corruptDatabase(
                path: databaseURL.path,
                message: "the SQLite header is shorter than the application identity field"
            )
        }
        return data[68..<72].reduce(0) { ($0 << 8) | Int($1) }
    }

    private func journalMode(_ databasePath: String) throws -> String {
        let connection = try SQLiteConnection(
            path: databasePath,
            createIfNeeded: false,
            readOnly: true,
            profile: .portableArtifact
        )
        defer { try? connection.close() }
        return try XCTUnwrap(connection.query("PRAGMA journal_mode").first?.first ?? nil)
            .lowercased()
    }

    private func sidecarFingerprints(
        databasePath: String
    ) throws -> [String: StateFileFingerprint] {
        var fingerprints: [String: StateFileFingerprint] = [:]
        for suffix in ["-journal", "-wal", "-shm"] {
            let path = databasePath + suffix
            if FileManager.default.fileExists(atPath: path) {
                fingerprints[suffix] = try StateMaintenanceFileSupport.fingerprint(path)
            }
        }
        return fingerprints
    }

    private func event(id: String) -> EventRecord {
        EventRecord(
            id: id,
            timestamp: "2026-07-14T00:00:00Z",
            severity: .info,
            type: "sqlite.hardening",
            source: "sqlite-hardening-tests",
            projectID: nil,
            serviceName: nil,
            runtimeAdapter: nil,
            message: "SQLite hardening integration event",
            payloadJSONRedacted: "{}"
        )
    }

    private func assertTransactionInvariant(
        _ error: any Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .transactionInvariantViolation = error as? StateStoreError else {
            return XCTFail("Expected transactionInvariantViolation, got \(error)", file: file, line: line)
        }
    }

    private func assertPathPolicyFailure(
        tryResult: () throws -> Void,
        expectedPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try tryResult(), file: file, line: line) { error in
            guard case .pathPolicyViolation(let path, _) = error as? StateStoreError else {
                return XCTFail("Expected pathPolicyViolation, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(path, expectedPath, file: file, line: line)
        }
    }

    private func killSQLiteSession(
        databasePath: String,
        script: String,
        marker: String
    ) throws {
        let executable = "/usr/bin/sqlite3"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw StateStoreError.openFailed(
                path: executable,
                message: "the required macOS sqlite3 executable is unavailable"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [databasePath]
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        input.fileHandleForWriting.write(Data((script + "\n").utf8))

        var captured = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !String(decoding: captured, as: UTF8.self).contains(marker), ContinuousClock.now < deadline {
            var readiness = pollfd(
                fd: output.fileHandleForReading.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let result = poll(&readiness, 1, 100)
            if result > 0, readiness.revents & Int16(POLLIN) != 0 {
                captured.append(output.fileHandleForReading.availableData)
            } else if result < 0, errno != EINTR {
                break
            }
            if !process.isRunning { break }
        }

        guard String(decoding: captured, as: UTF8.self).contains(marker) else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let stderr = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw StateStoreError.ioFailure(
                path: databasePath,
                message: "the sqlite3 process did not reach durable test marker \(marker): \(stderr)"
            )
        }

        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertEqual(
            String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            ""
        )
    }

    private func insertEventSQL(id: String) -> String {
        """
        INSERT INTO event_ledger (
            id, timestamp, severity, type, source, project_id, service_name,
            runtime_adapter, message, payload_json_redacted
        ) VALUES (
            '\(id)', '2026-07-14T00:00:00Z', 'info', 'sqlite.power-loss',
            'sqlite-hardening-tests', NULL, NULL, NULL,
            'SQLite process-termination integration event', '{}'
        )
        """
    }
}

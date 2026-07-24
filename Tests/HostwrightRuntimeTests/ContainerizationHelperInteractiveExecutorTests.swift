import Foundation
import XCTest
@testable import HostwrightRuntime

final class ContainerizationHelperInteractiveExecutorTests: XCTestCase {
    func testQualifiedSubsetRejectsUnsupportedOperationsBeforeRequesterInvocation() async throws {
        let snapshot = helperSnapshot()
        let requester = RecordingContainerizationInteractiveRequester(
            snapshot: snapshot,
            inventory: try inventory(lifecycle: .stopped),
            usage: usage()
        )
        let executor = ContainerizationHelperInteractiveExecutor(requester: requester)

        XCTAssertEqual(
            ContainerizationHelperInteractiveExecutor.supportedOperations(in: snapshot),
            Set([.inspect, .stats, .logsFollow])
        )
        do {
            _ = try await executor.execute(
                .exec(
                    resourceIdentifier: managedIdentifier,
                    arguments: ["/bin/true"],
                    interactive: false,
                    tty: false,
                    workingDirectory: nil
                ),
                capabilitySnapshot: snapshot,
                timeoutMilliseconds: 1_000
            ) { _ in }
            XCTFail("Expected unsupported helper exec to fail.")
        } catch {
            guard case .capabilityUnavailable(let operation, let reason) =
                    error as? RuntimeInteractiveError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, .exec)
            XCTAssertTrue(reason.contains("does not expose exec"))
        }
        let totalCallCount = await requester.totalCallCount()
        XCTAssertEqual(totalCallCount, 0)
    }

    func testInspectAndStatsEmitCanonicalNormalizedRedactedFrames() async throws {
        let snapshot = helperSnapshot()
        let requester = RecordingContainerizationInteractiveRequester(
            snapshot: snapshot,
            inventory: try inventory(lifecycle: .stopped),
            usage: usage()
        )
        let executor = ContainerizationHelperInteractiveExecutor(requester: requester)
        let inspectFrames = HelperLockedFrames()

        let inspectResult = try await executor.execute(
            .inspect(resourceIdentifier: managedIdentifier),
            capabilitySnapshot: snapshot,
            timeoutMilliseconds: 1_000
        ) { inspectFrames.append($0) }

        XCTAssertEqual(inspectResult.operation, .inspect)
        XCTAssertEqual(inspectFrames.values.map(\.sequence), [0, 1, 2])
        let inspectData = inspectFrames.payload(for: .standardOutput)
        let inspectText = String(decoding: inspectData, as: UTF8.self)
        XCTAssertTrue(inspectText.contains(#""providerID":"apple-containerization""#))
        XCTAssertTrue(inspectText.contains(#""schemaVersion":1"#))
        XCTAssertTrue(inspectText.contains(#""value":"[REDACTED]""#))
        XCTAssertFalse(inspectText.contains("super-secret"))

        let statsFrames = HelperLockedFrames()
        let statsResult = try await executor.execute(
            .stats(resourceIdentifier: managedIdentifier),
            capabilitySnapshot: snapshot,
            timeoutMilliseconds: 1_000
        ) { statsFrames.append($0) }

        XCTAssertEqual(statsResult.operation, .stats)
        XCTAssertEqual(statsFrames.values.map(\.sequence), [0, 1, 2])
        let statsText = String(decoding: statsFrames.payload(for: .standardOutput), as: UTF8.self)
        XCTAssertTrue(statsText.contains(#""cpuUsageMicroseconds":11"#))
        XCTAssertTrue(statsText.contains(#""memoryUsageBytes":22"#))
        XCTAssertTrue(statsText.contains(#""processCount":8"#))
        XCTAssertTrue(inspectFrames.values.suffix(2).allSatisfy(\.endOfStream))
        XCTAssertTrue(statsFrames.values.suffix(2).allSatisfy(\.endOfStream))
    }

    func testLogFollowUsesMonotonicCursorAndRecoversOneHelperRestart() async throws {
        let snapshot = helperSnapshot()
        let requester = RecordingContainerizationInteractiveRequester(
            snapshot: snapshot,
            inventory: try inventory(lifecycle: .stopped),
            usage: usage(),
            logChunks: [
                ContainerizationHelperLogChunk(
                    resourceIdentifier: managedIdentifier,
                    text: "first\n",
                    cursorStart: 0,
                    cursorEnd: 6,
                    atCurrentEnd: false
                ),
                ContainerizationHelperLogChunk(
                    resourceIdentifier: managedIdentifier,
                    text: "second\n",
                    cursorStart: 6,
                    cursorEnd: 13,
                    atCurrentEnd: true
                )
            ],
            transientLogFailures: 1
        )
        let executor = ContainerizationHelperInteractiveExecutor(requester: requester)
        let frames = HelperLockedFrames()

        let result = try await executor.execute(
            .logsFollow(resourceIdentifier: managedIdentifier, tail: 100),
            capabilitySnapshot: snapshot,
            timeoutMilliseconds: 2_000
        ) { frames.append($0) }

        XCTAssertEqual(result.operation, .logsFollow)
        XCTAssertEqual(
            String(decoding: frames.payload(for: .standardOutput), as: UTF8.self),
            "first\nsecond\n"
        )
        XCTAssertEqual(frames.values.map(\.sequence), [0, 1, 2, 3])
        let logRequestCursors = await requester.logRequestCursors()
        let capabilityCallCount = await requester.capabilityCallCount()
        XCTAssertEqual(logRequestCursors, [nil, nil, 6])
        XCTAssertEqual(capabilityCallCount, 2)
        XCTAssertTrue(frames.values.suffix(2).allSatisfy(\.endOfStream))
    }

    func testStaleCapabilityFailsBeforeObservation() async throws {
        let confirmed = helperSnapshot(fingerprint: String(repeating: "a", count: 64))
        let current = helperSnapshot(fingerprint: String(repeating: "b", count: 64))
        let requester = RecordingContainerizationInteractiveRequester(
            snapshot: current,
            inventory: try inventory(lifecycle: .stopped),
            usage: usage()
        )
        let executor = ContainerizationHelperInteractiveExecutor(requester: requester)

        do {
            _ = try await executor.execute(
                .inspect(resourceIdentifier: managedIdentifier),
                capabilitySnapshot: confirmed,
                timeoutMilliseconds: 1_000
            ) { _ in }
            XCTFail("Expected stale capability refusal.")
        } catch {
            guard case .capabilityUnavailable(let operation, let reason) =
                    error as? RuntimeInteractiveError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, .inspect)
            XCTAssertTrue(reason.contains("stale"))
        }
        let capabilityCallCount = await requester.capabilityCallCount()
        let inventoryCallCount = await requester.inventoryCallCount()
        XCTAssertEqual(capabilityCallCount, 1)
        XCTAssertEqual(inventoryCallCount, 0)
    }

    private var managedIdentifier: String {
        RuntimeServiceIdentity(
            projectName: "phase04",
            serviceName: "helper"
        ).managedResourceIdentifier
    }

    private func helperSnapshot(
        fingerprint: String = String(repeating: "a", count: 64)
    ) -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerization,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationHelper,
                        version: "0.0.2",
                        build: "test",
                        fingerprint: fingerprint
                    ),
                    RuntimeProviderComponent(
                        identifier: .containerizationHelperProtocolV1,
                        version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                        build: "test",
                        fingerprint: String(repeating: "b", count: 64)
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationFramework,
                        version: RuntimeProviderCapabilityContract.containerizationFrameworkVersion,
                        build: "test",
                        fingerprint: String(repeating: "c", count: 64)
                    )
                ],
                minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(major: 26),
                macOSBuild: "25A1",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map {
                RuntimeProviderFeatureStatus(
                    feature: $0,
                    state: .available,
                    reason: .implemented
                )
            }
        )
    }

    private func inventory(
        lifecycle: RuntimeInventoryLifecycleState
    ) throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS",
                architecture: "arm64",
                runtimeVersion: "0.35.0",
                services: [
                    RuntimeInventoryService(
                        identifier: "hostwright-containerization-helper",
                        state: .running,
                        required: true
                    )
                ]
            ),
            containers: [
                RuntimeInventoryContainer(
                    runtimeID: managedIdentifier,
                    name: managedIdentifier,
                    imageReference: "fixture@sha256:\(String(repeating: "d", count: 64))",
                    lifecycle: lifecycle,
                    health: RuntimeInventoryHealth(availability: .notConfigured),
                    labels: [],
                    initConfiguration: RuntimeInventoryInitConfiguration(
                        executable: "/bin/fixture",
                        arguments: [],
                        environment: [
                            RuntimeInventoryEnvironmentEntry(
                                name: "API_TOKEN",
                                value: "super-secret"
                            )
                        ]
                    ),
                    ports: [],
                    mounts: [],
                    networks: [],
                    services: []
                )
            ],
            images: [],
            networks: [],
            volumes: []
        )
    }

    private func usage() -> RuntimeResourceUsageSnapshot {
        RuntimeResourceUsageSnapshot(
            resourceIdentifier: managedIdentifier,
            cpuUsageMicroseconds: 11,
            memoryUsageBytes: 22,
            memoryLimitBytes: 33,
            networkReceiveBytes: 44,
            networkTransmitBytes: 55,
            blockReadBytes: 66,
            blockWriteBytes: 77,
            processCount: 8
        )
    }
}

private actor RecordingContainerizationInteractiveRequester:
    ContainerizationHelperInteractiveRequesting
{
    private let snapshot: RuntimeCapabilitySnapshot
    private let inventory: RuntimeInventory
    private let usage: RuntimeResourceUsageSnapshot
    private var logChunks: [ContainerizationHelperLogChunk]
    private var transientLogFailures: Int
    private var capabilityCalls = 0
    private var inventoryCalls = 0
    private var usageCalls = 0
    private var logCursors: [UInt64?] = []

    init(
        snapshot: RuntimeCapabilitySnapshot,
        inventory: RuntimeInventory,
        usage: RuntimeResourceUsageSnapshot,
        logChunks: [ContainerizationHelperLogChunk] = [],
        transientLogFailures: Int = 0
    ) {
        self.snapshot = snapshot
        self.inventory = inventory
        self.usage = usage
        self.logChunks = logChunks
        self.transientLogFailures = transientLogFailures
    }

    func interactiveCapabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        capabilityCalls += 1
        return snapshot
    }

    func interactiveInventory() async throws -> RuntimeInventory {
        inventoryCalls += 1
        return inventory
    }

    func interactiveResourceUsage(
        resourceIdentifier: String
    ) async throws -> RuntimeResourceUsageSnapshot {
        usageCalls += 1
        return usage
    }

    func interactiveLogChunk(
        resourceIdentifier: String,
        lineLimit: Int,
        cursor: UInt64?,
        startAtEnd: Bool,
        maximumBytes: Int
    ) async throws -> ContainerizationHelperLogChunk {
        _ = lineLimit
        _ = startAtEnd
        _ = maximumBytes
        logCursors.append(cursor)
        if transientLogFailures > 0 {
            transientLogFailures -= 1
            throw ContainerizationHelperClientError.helperExited
        }
        guard !logChunks.isEmpty else {
            throw ContainerizationHelperClientError.invalidResponse
        }
        return logChunks.removeFirst()
    }

    func totalCallCount() -> Int {
        capabilityCalls + inventoryCalls + usageCalls + logCursors.count
    }

    func capabilityCallCount() -> Int {
        capabilityCalls
    }

    func inventoryCallCount() -> Int {
        inventoryCalls
    }

    func logRequestCursors() -> [UInt64?] {
        logCursors
    }
}

private final class HelperLockedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RuntimeStreamEnvelope] = []

    func append(_ frame: RuntimeStreamEnvelope) {
        lock.withLock { frames.append(frame) }
    }

    var values: [RuntimeStreamEnvelope] {
        lock.withLock { frames }
    }

    func payload(for stream: RuntimeStreamName) -> Data {
        lock.withLock {
            frames
                .filter { $0.stream == stream && !$0.endOfStream }
                .reduce(into: Data()) { $0.append($1.payload) }
        }
    }
}

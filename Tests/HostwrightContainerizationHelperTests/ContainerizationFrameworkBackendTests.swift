import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime
import XCTest

@testable import HostwrightContainerizationHelper

final class ContainerizationFrameworkBackendTests: XCTestCase {
    func testLifecyclePersistsOwnershipAndVerifiesEveryEffect() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let request = try createRequest(context: context)

        let created = try await backend.create(request, context: context)
        XCTAssertEqual(created.lifecycle, .created)
        XCTAssertEqual(try store.loadRecords().map(\.phase), [.created])

        let mutation = ContainerizationHelperMutationPayload(
            resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID
        )
        let started = try await backend.start(mutation, context: context)
        XCTAssertEqual(started.lifecycle, .running)
        let stopped = try await backend.stop(mutation, context: context)
        XCTAssertEqual(stopped.lifecycle, .stopped)
        XCTAssertEqual(try store.loadRecords().map(\.phase), [.stopped])
        _ = try await backend.start(mutation, context: context)
        let restarted = try await backend.restart(mutation, context: context)
        XCTAssertEqual(restarted.lifecycle, .running)

        let observation = try await backend.observe(.init(includeResourceUsage: true))
        let inventory = try observation.validatedInventory()
        XCTAssertEqual(inventory.containers.count, 1)
        XCTAssertEqual(inventory.containers[0].lifecycle, .running)
        XCTAssertEqual(inventory.containers[0].ownership?.resourceUUID, context.resourceUUID)
        XCTAssertEqual(inventory.containers[0].usage?.cpuUsageMicroseconds, 10)

        let deleted = try await backend.delete(mutation, context: context)
        XCTAssertEqual(deleted.lifecycle, .missing)
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let operations = await driver.operations()
        XCTAssertEqual(
            operations,
            ["resolve", "create", "start", "stop", "start", "restart", "usage", "images", "delete"]
        )
    }

    func testRestartRecoveryReportsStoppedUntilExplicitStart() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let context = mutationContext()
        var record = ContainerizationHelperPersistedRecord(
            request: try createRequest(context: context),
            context: context
        )
        record.command = ["/bin/sleep", "30"]
        record.workingDirectory = "/"
        record.phase = .running
        try store.save(record)

        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let observation = try await backend.observe(.init(includeResourceUsage: false))
        XCTAssertEqual(try observation.validatedInventory().containers[0].lifecycle, .stopped)
        XCTAssertEqual(try store.loadRecords()[0].failureCategory, "helper-restarted")

        let result = try await backend.start(
            ContainerizationHelperMutationPayload(
                resourceIdentifier: record.resourceIdentifier,
                resourceUUID: record.resourceUUID
            ),
            context: context
        )
        XCTAssertEqual(result.lifecycle, .running)
        let operations = await driver.operations()
        XCTAssertEqual(operations, ["images", "start"])
    }

    func testPreparedDeleteFinishesThroughObservation() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let context = mutationContext()
        var record = ContainerizationHelperPersistedRecord(
            request: try createRequest(context: context),
            context: context
        )
        record.command = ["/bin/true"]
        record.phase = .preparedDelete
        try store.save(record)

        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let observation = try await backend.observe(.init())
        XCTAssertTrue(try observation.validatedInventory().containers.isEmpty)
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let operations = await driver.operations()
        XCTAssertEqual(operations, ["delete", "images"])
    }

    func testCreateRejectsLabelsThatDoNotMatchFenceBeforeDriverMutation() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let valid = try createRequest(context: context)
        let invalid = ContainerizationHelperCreatePayload(
            resourceIdentifier: valid.resourceIdentifier,
            resourceUUID: valid.resourceUUID,
            projectUUID: valid.projectUUID,
            image: valid.image,
            command: valid.command,
            environment: valid.environment,
            labels: valid.labels.map {
                $0.key == RuntimeManagedResourceIdentity.fencingTokenLabel
                    ? RuntimeInventoryLabel(key: $0.key, value: UUID().uuidString.lowercased())
                    : $0
            }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await backend.create(invalid, context: context)
        }
        XCTAssertTrue(try store.loadRecords().isEmpty)
        let operations = await driver.operations()
        XCTAssertEqual(operations, [])
    }

    func testStopRejectsAStaleFenceBeforeDriverMutation() async throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ContainerizationHelperStateStore(
            rootURL: parent.appendingPathComponent("state", isDirectory: true)
        )
        let driver = RecordingContainerizationDriver()
        let backend = try ContainerizationFrameworkBackend(
            snapshot: snapshot(),
            store: store,
            driver: driver
        )
        let context = mutationContext()
        let request = try createRequest(context: context)
        _ = try await backend.create(request, context: context)
        let mutation = ContainerizationHelperMutationPayload(
            resourceIdentifier: request.resourceIdentifier,
            resourceUUID: request.resourceUUID
        )
        _ = try await backend.start(mutation, context: context)

        let staleContext = mutationContext(
            fencingToken: "44444444-4444-4444-8444-444444444444"
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await backend.stop(mutation, context: staleContext)
        }

        XCTAssertEqual(try store.loadRecords().map(\.phase), [.running])
        let operations = await driver.operations()
        XCTAssertEqual(operations, ["resolve", "create", "start"])
    }

    func testConfigurationRejectsTamperedKernelAndUnsafeConfigurationMode() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let kernel = parent.appendingPathComponent("kernel", isDirectory: false)
        let kernelBytes = Data("kernel".utf8)
        try kernelBytes.write(to: kernel, options: .withoutOverwriting)
        XCTAssertEqual(chmod(kernel.path, 0o600), 0)
        let layout = parent.appendingPathComponent("layout", isDirectory: true)
        XCTAssertEqual(mkdir(layout.path, 0o700), 0)
        for name in ["blobs"] {
            XCTAssertEqual(mkdir(layout.appendingPathComponent(name).path, 0o700), 0)
        }
        for name in ["oci-layout", "index.json"] {
            let file = layout.appendingPathComponent(name)
            try Data("{}".utf8).write(to: file, options: .withoutOverwriting)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
        }
        let digest = SHA256.hash(data: kernelBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let validConfiguration = configuration(
            parent: parent,
            kernel: kernel,
            layout: layout,
            kernelDigest: digest
        )
        XCTAssertNoThrow(try validConfiguration.validate())

        let tampered = configuration(
            parent: parent,
            kernel: kernel,
            layout: layout,
            kernelDigest: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(try tampered.validate()) { error in
            XCTAssertEqual(error as? ContainerizationHelperConfigurationError, .assetDigestMismatch)
        }

        let configURL = parent.appendingPathComponent("helper.json")
        let encoder = JSONEncoder()
        try encoder.encode(validConfiguration).write(to: configURL, options: .withoutOverwriting)
        XCTAssertEqual(chmod(configURL.path, 0o644), 0)
        XCTAssertThrowsError(try ContainerizationHelperConfiguration.load(at: configURL)) { error in
            XCTAssertEqual(error as? ContainerizationHelperConfigurationError, .configurationUnsafe)
        }
    }

    func testInitfsCacheIdentityIsBoundToPinnedFrameworkAndVariant() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let kernel = parent.appendingPathComponent("kernel", isDirectory: false)
        let kernelBytes = Data("kernel".utf8)
        try kernelBytes.write(to: kernel, options: .withoutOverwriting)
        XCTAssertEqual(chmod(kernel.path, 0o600), 0)
        let layout = parent.appendingPathComponent("layout", isDirectory: true)
        XCTAssertEqual(mkdir(layout.path, 0o700), 0)
        XCTAssertEqual(mkdir(layout.appendingPathComponent("blobs").path, 0o700), 0)
        for name in ["oci-layout", "index.json"] {
            let file = layout.appendingPathComponent(name)
            try Data("{}".utf8).write(to: file, options: .withoutOverwriting)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
        }
        let digest = SHA256.hash(data: kernelBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let first = configuration(
            parent: parent,
            kernel: kernel,
            layout: layout,
            kernelDigest: digest,
            variantDigest: "sha256:" + String(repeating: "b", count: 64)
        )
        let replacement = configuration(
            parent: parent,
            kernel: kernel,
            layout: layout,
            kernelDigest: digest,
            variantDigest: "sha256:" + String(repeating: "c", count: 64)
        )

        XCTAssertNotEqual(first.initfsCacheFileName, replacement.initfsCacheFileName)
        XCTAssertEqual(
            first.initfsCacheFileName,
            "initfs-0.35.0-\(String(repeating: "b", count: 64)).ext4"
        )
        XCTAssertFalse(first.initfsCacheFileName.contains(":"))
    }

    private func createRequest(
        context: RuntimeMutationContext
    ) throws -> ContainerizationHelperCreatePayload {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        return ContainerizationHelperCreatePayload(
            resourceIdentifier: RuntimeManagedResourceIdentity.resourceIdentifier(for: identity),
            resourceUUID: context.resourceUUID,
            projectUUID: context.projectResourceUUID,
            image: RecordingContainerizationDriver.image,
            command: ["/bin/sleep", "30"],
            environment: [RuntimeInventoryEnvironmentEntry(name: "MODE", value: "test")],
            labels: try RuntimeManagedResourceIdentity.labels(for: identity, context: context)
                .map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
        )
    }

    private func mutationContext(
        fencingToken: String = "33333333-3333-4333-8333-333333333333"
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerization,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "operation-1",
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 1,
            projectResourceUUID: "22222222-2222-4222-8222-222222222222",
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: fencingToken
        )
    }

    private func snapshot() -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerization,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationHelper,
                        version: HostwrightIdentity.version,
                        build: "test",
                        fingerprint: "abcdef0"
                    ),
                    RuntimeProviderComponent(
                        identifier: .containerizationHelperProtocolV1,
                        version: "1",
                        build: "test",
                        fingerprint: "abcdef1"
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationFramework,
                        version: "0.35.0",
                        build: "test",
                        fingerprint: "abcdef2"
                    )
                ],
                minimumMacOSVersion: .init(major: 26),
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: .init(major: 26),
                macOSBuild: "25A123",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map {
                RuntimeProviderFeatureStatus(
                    feature: $0,
                    state: .experimental,
                    reason: .qualificationIncomplete
                )
            }
        )
    }

    private func configuration(
        parent: URL,
        kernel: URL,
        layout: URL,
        kernelDigest: String,
        variantDigest: String = "sha256:" + String(repeating: "b", count: 64)
    ) -> ContainerizationHelperConfiguration {
        ContainerizationHelperConfiguration(
            schema: 1,
            framework: "0.35.0",
            dataRootPath: parent.appendingPathComponent("data").path,
            runtimeDirectoryPath: parent.appendingPathComponent("run").path,
            kernelPath: kernel.path,
            kernelSHA256: kernelDigest,
            initImageLayoutPath: layout.path,
            initImageReference: "ghcr.io/apple/containerization/vminit:0.35.0",
            initImageDescriptorDigest: "sha256:" + String(repeating: "a", count: 64),
            initImageVariantDigest: variantDigest,
            rootfsSizeBytes: 1_073_741_824
        )
    }

    private func makePrivateParent() throws -> URL {
        let url = URL(
            fileURLWithPath: "/tmp/hostwright-helper-\(getpid())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard mkdir(url.path, 0o700) == 0 else {
            throw ContainerizationHelperPersistenceError.operationFailed
        }
        return url
    }
}

private actor RecordingContainerizationDriver: ContainerizationHelperRuntimeDriving {
    static let image = ContainerizationHelperImageEvidence(
        reference: "example.local/demo@sha256:" + String(repeating: "c", count: 64),
        descriptorDigest: "sha256:" + String(repeating: "c", count: 64),
        variantDigest: "sha256:" + String(repeating: "d", count: 64),
        architecture: "arm64",
        operatingSystem: "linux"
    )

    private var events: [String] = []

    func resolveProcess(
        for request: ContainerizationHelperCreatePayload
    ) async throws -> ContainerizationHelperResolvedProcess {
        events.append("resolve")
        return ContainerizationHelperResolvedProcess(
            command: request.command,
            environment: request.environment,
            workingDirectory: "/",
            user: nil
        )
    }

    func localImageEvidence(reference: String) async throws -> ContainerizationHelperImageEvidence {
        Self.image
    }

    func listImages() async throws -> [ContainerizationHelperImageRecord] {
        events.append("images")
        return [ContainerizationHelperImageRecord(evidence: Self.image, references: [Self.image.reference])]
    }

    func create(_ record: ContainerizationHelperPersistedRecord) async throws { events.append("create") }
    func start(_ record: ContainerizationHelperPersistedRecord) async throws { events.append("start") }
    func restart(_ record: ContainerizationHelperPersistedRecord) async throws { events.append("restart") }
    func stop(_ record: ContainerizationHelperPersistedRecord) async throws { events.append("stop") }
    func delete(_ record: ContainerizationHelperPersistedRecord) async throws { events.append("delete") }

    func usage(resourceIdentifier: String) async throws -> ContainerizationHelperResourceUsage {
        events.append("usage")
        return ContainerizationHelperResourceUsage(
            resourceIdentifier: resourceIdentifier,
            cpuUsageMicroseconds: 10,
            memoryUsageBytes: 20,
            memoryLimitBytes: 30,
            networkReceiveBytes: 40,
            networkTransmitBytes: 50,
            blockReadBytes: 60,
            blockWriteBytes: 70,
            processCount: 8
        )
    }

    func shutdown() async {}
    func operations() -> [String] { events }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

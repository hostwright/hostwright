import Foundation
import Testing
@testable import HostwrightStorage

@Suite("Storage provider client")
struct StorageProviderClientTests {
    @Test
    func invokesTypedCanonicalOperation() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 1_024
        )
        let client = try StorageProviderClient(
            provider: provider,
            requestID: {
                UUID(
                    uuidString:
                        "00000000-0000-4000-8000-000000000001"
                )!
            }
        )

        let result: LocalStorageMutationResult = try await client.invoke(
            operation: .create,
            mutationContext: context(),
            idempotencyKey: "client-create",
            payload: LocalStorageCreatePayload(
                name: "database",
                capacityBytes: 512
            ),
            result: LocalStorageMutationResult.self
        )

        #expect(result.volume?.name == "database")
        #expect(result.volume?.capacityBytes == 512)
    }

    @Test
    func preservesNormalizedProviderFailure() async throws {
        let harness = try LocalStorageProviderTestHarness()
        defer { harness.cleanup() }
        let provider = try LocalStorageProvider(
            rootURL: harness.providerRoot,
            totalCapacityBytes: 128
        )
        let client = try StorageProviderClient(provider: provider)

        await #expect(throws: StorageProviderInvocationFailure.self) {
            let _: LocalStorageMutationResult = try await client.invoke(
                operation: .create,
                mutationContext: context(),
                idempotencyKey: "client-over-capacity",
                payload: LocalStorageCreatePayload(
                    name: "database",
                    capacityBytes: 512
                ),
                result: LocalStorageMutationResult.self
            )
        }
    }

    @Test
    func refusesUnavailableCapabilityBeforeInvocation() async throws {
        let provider = CountingProvider()
        let client = try StorageProviderClient(provider: provider)

        await #expect(throws: StorageProviderCapabilityError.self) {
            let _: LocalStorageMutationResult = try await client.invoke(
                operation: .backup,
                mutationContext: context(),
                idempotencyKey: "client-unavailable",
                payload: LocalStorageUnsupportedPayload(),
                result: LocalStorageMutationResult.self
            )
        }
        #expect(await provider.invocations == 0)
    }

    private func context() -> StorageProviderMutationContext {
        StorageProviderMutationContext(
            projectUUID: UUID(
                uuidString: "00000000-0000-4000-8000-000000000010"
            )!,
            projectGeneration: 1,
            resourceUUID: UUID(
                uuidString: "00000000-0000-4000-8000-000000000020"
            )!,
            resourceGeneration: 1,
            fencingToken: UUID(
                uuidString: "00000000-0000-4000-8000-000000000030"
            )!
        )
    }

}

private actor CountingProvider: StorageProviderSPI {
    private(set) var invocations = 0

    func descriptor() async throws -> StorageProviderDescriptor {
        let descriptor = LocalStorageProviderContract.descriptor
        return StorageProviderDescriptor(
            providerID: descriptor.providerID,
            providerVersion: descriptor.providerVersion,
            capabilities: descriptor.capabilities.map {
                $0.operation == .backup
                    ? StorageProviderCapability(
                        operation: .backup,
                        state: .unavailable,
                        reason: "disabled-by-test"
                    )
                    : $0
            },
            maximumRequestBytes: descriptor.maximumRequestBytes,
            maximumResultBytes: descriptor.maximumResultBytes
        )
    }

    func invoke(canonicalRequest: Data) async throws -> Data {
        invocations += 1
        return canonicalRequest
    }

    func cancel(requestID: UUID) async {}
}

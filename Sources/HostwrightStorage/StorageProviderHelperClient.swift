import Foundation

public actor StorageProviderHelperClient: StorageProviderSPI {
    public let configuration:
        StorageProviderHelperBootstrapConfiguration

    private var session: StorageProviderHelperSession?

    public init(
        configuration:
            StorageProviderHelperBootstrapConfiguration
    ) {
        self.configuration = configuration
    }

    public func descriptor() async throws -> StorageProviderDescriptor {
        let descriptor = LocalStorageProviderContract.descriptor
        try StorageProviderDescriptorValidator.validate(descriptor)
        return descriptor
    }

    public func invoke(canonicalRequest: Data) async throws -> Data {
        let active = try await activeSession()
        do {
            let request =
                try StorageProviderCanonicalTransportJSON.decodeRequest(
                    canonicalRequest
                )
            let frame = try StorageProviderFraming.frameRequest(
                canonicalRequest
            )
            let response = try await active.exchange(
                frame: frame,
                deadlineUnixMilliseconds:
                    request.deadlineUnixMilliseconds
            )
            return try StorageProviderFraming.decodeResult(response.frame)
        } catch {
            try? await active.close()
            session = nil
            throw error
        }
    }

    public func cancel(requestID: UUID) async {
        guard let active = session else {
            return
        }
        try? await active.close()
        session = nil
    }

    public func close() async throws {
        guard let active = session else {
            return
        }
        session = nil
        try await active.close()
    }

    private func activeSession() async throws
        -> StorageProviderHelperSession
    {
        if let session {
            return session
        }
        let launched = try await StorageProviderHelperBootstrap(
            configuration: configuration
        ).launch()
        session = launched
        return launched
    }
}

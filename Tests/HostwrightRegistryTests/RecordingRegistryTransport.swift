import Foundation
import HostwrightRegistry

final class RecordingRegistryTransport:
    RegistrySynchronousHTTPTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var responses: [RegistryTransportResponse]
    private var recordedRequests: [RegistryTransportRequest] = []

    init(_ responses: [RegistryTransportResponse]) {
        self.responses = responses
    }

    var requests: [RegistryTransportRequest] {
        lock.withLock { recordedRequests }
    }

    func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        try lock.withLock {
            recordedRequests.append(request)
            guard !responses.isEmpty else {
                throw RegistryTransportError.transportFailed
            }
            return responses.removeFirst()
        }
    }
}

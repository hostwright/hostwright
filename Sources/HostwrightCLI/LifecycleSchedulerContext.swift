import Foundation
import HostwrightReconciler
import HostwrightScheduler
import HostwrightState

public struct LifecycleSchedulerHostSnapshot: Sendable {
    public let capacity: SchedulerNodeCapacitySnapshot
    public let pressure: SchedulerHostPressureRecord
    public let configDigest: String
    public let profileDigest: String
    public let labels: [String: String]
    public let observedAt: Date

    public init(
        capacity: SchedulerNodeCapacitySnapshot,
        pressure: SchedulerHostPressureRecord,
        configDigest: String,
        profileDigest: String,
        labels: [String: String],
        observedAt: Date
    ) {
        self.capacity = capacity
        self.pressure = pressure
        self.configDigest = configDigest
        self.profileDigest = profileDigest
        self.labels = labels
        self.observedAt = observedAt
    }
}

public struct LifecycleSchedulerContext: Sendable {
    public let subjectID: String
    public let refresh: @Sendable () throws -> LifecycleSchedulerHostSnapshot
    public let authorize: @Sendable (LifecyclePlan) throws -> Void

    public init(
        subjectID: String,
        authorize: @escaping @Sendable (LifecyclePlan) throws -> Void = { _ in },
        refresh: @escaping @Sendable () throws -> LifecycleSchedulerHostSnapshot
    ) {
        self.subjectID = subjectID
        self.refresh = refresh
        self.authorize = authorize
    }
}

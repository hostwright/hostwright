import CryptoKit
import Foundation
import HostwrightManifest

public enum MaintenanceAdmissionReason: String, Codable, Equatable, Sendable {
    case noPolicy = "no-policy"
    case safetyRecovery = "safety-recovery"
    case activeWindow = "active-window"
    case emergencyOverride = "emergency-override"
    case outsideWindow = "outside-window"
    case deadlineExpired = "deadline-expired"
    case cancelled
}

public struct MaintenanceWindowOccurrence: Codable, Equatable, Hashable, Sendable {
    public let windowID: String
    public let startsAt: String
    public let endsAt: String

    public init(windowID: String, startsAt: String, endsAt: String) {
        self.windowID = windowID
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

public struct MaintenanceAdmissionDecision: Codable, Equatable, Sendable {
    public let admitted: Bool
    public let reason: MaintenanceAdmissionReason
    public let policySHA256: String
    public let actionClasses: [HostwrightMaintenanceActionClass]
    public let activeWindow: MaintenanceWindowOccurrence?
    public let nextWindow: MaintenanceWindowOccurrence?
    public let deadlineAt: String?

    public init(
        admitted: Bool,
        reason: MaintenanceAdmissionReason,
        policySHA256: String,
        actionClasses: [HostwrightMaintenanceActionClass],
        activeWindow: MaintenanceWindowOccurrence?,
        nextWindow: MaintenanceWindowOccurrence?,
        deadlineAt: String?
    ) {
        self.admitted = admitted
        self.reason = reason
        self.policySHA256 = policySHA256
        self.actionClasses = actionClasses.sorted { $0.rawValue < $1.rawValue }
        self.activeWindow = activeWindow
        self.nextWindow = nextWindow
        self.deadlineAt = deadlineAt
    }
}

public enum MaintenanceWindowEvaluator {

    public static func evaluate(
        policy: HostwrightMaintenancePolicy?,
        actions: [HostwrightMaintenanceActionClass],
        now: Date,
        deferredAt: Date? = nil,
        cancelled: Bool = false,
        emergencyOverrideAuthorized: Bool = false
    ) -> MaintenanceAdmissionDecision {
        let normalizedActions = Array(Set(actions)).sorted { $0.rawValue < $1.rawValue }
        if normalizedActions.contains(where: { !$0.isElective }) {
            return MaintenanceAdmissionDecision(
                admitted: true,
                reason: .safetyRecovery,
                policySHA256: policy.map(policySHA256) ?? String(repeating: "0", count: 64),
                actionClasses: normalizedActions,
                activeWindow: nil,
                nextWindow: nil,
                deadlineAt: nil
            )
        }
        guard let policy else {
            return MaintenanceAdmissionDecision(
                admitted: true,
                reason: .noPolicy,
                policySHA256: String(repeating: "0", count: 64),
                actionClasses: normalizedActions,
                activeWindow: nil,
                nextWindow: nil,
                deadlineAt: nil
            )
        }
        let digest = policySHA256(policy)
        let deadline = deferredAt.map {
            $0.addingTimeInterval(TimeInterval(policy.maximumDeferral))
        }
        let deadlineText = deadline.map { formatter().string(from: $0) }
        let candidates = occurrences(policy: policy, actions: normalizedActions, around: now)
        let active = candidates
            .filter { occurrence in
                let bounds = interval(occurrence)
                return now >= bounds.start && now < bounds.end
            }
            .sorted { ($0.startsAt, $0.windowID) < ($1.startsAt, $1.windowID) }
            .first
        let next = candidates
            .filter { (formatter().date(from: $0.startsAt) ?? .distantPast) > now }
            .sorted { ($0.startsAt, $0.windowID) < ($1.startsAt, $1.windowID) }
            .first
        if cancelled {
            return MaintenanceAdmissionDecision(
                admitted: false,
                reason: .cancelled,
                policySHA256: digest,
                actionClasses: normalizedActions,
                activeWindow: active,
                nextWindow: next,
                deadlineAt: deadlineText
            )
        }
        if let deadline, now >= deadline {
            return MaintenanceAdmissionDecision(
                admitted: false,
                reason: .deadlineExpired,
                policySHA256: digest,
                actionClasses: normalizedActions,
                activeWindow: active,
                nextWindow: next,
                deadlineAt: deadlineText
            )
        }
        if emergencyOverrideAuthorized {
            return MaintenanceAdmissionDecision(
                admitted: true,
                reason: .emergencyOverride,
                policySHA256: digest,
                actionClasses: normalizedActions,
                activeWindow: active,
                nextWindow: next,
                deadlineAt: deadlineText
            )
        }
        if let active {
            return MaintenanceAdmissionDecision(
                admitted: true,
                reason: .activeWindow,
                policySHA256: digest,
                actionClasses: normalizedActions,
                activeWindow: active,
                nextWindow: next,
                deadlineAt: deadlineText
            )
        }
        return MaintenanceAdmissionDecision(
            admitted: false,
            reason: .outsideWindow,
            policySHA256: digest,
            actionClasses: normalizedActions,
            activeWindow: nil,
            nextWindow: next,
            deadlineAt: deadlineText
        )
    }

    public static func policySHA256(_ policy: HostwrightMaintenancePolicy) -> String {
        var components = [policy.timezone, String(policy.maximumDeferral)]
        for window in policy.windows.sorted(by: { $0.id < $1.id }) {
            components.append(window.id)
            components.append(window.actions.map(\.rawValue).sorted().joined(separator: ","))
            switch window.schedule {
            case .recurring(let recurring):
                components.append("recurring")
                components.append(recurring.weekdays.map(\.rawValue).sorted().joined(separator: ","))
                components.append(recurring.start)
                components.append(String(recurring.duration))
            case .oneShot(let oneShot):
                components.append("one-shot")
                components.append(oneShot.startsAt)
                components.append(String(oneShot.duration))
            }
        }
        return SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func occurrences(
        policy: HostwrightMaintenancePolicy,
        actions: [HostwrightMaintenanceActionClass],
        around now: Date
    ) -> [MaintenanceWindowOccurrence] {
        guard let timezone = TimeZone(identifier: policy.timezone) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        var values: [MaintenanceWindowOccurrence] = []
        for window in policy.windows where Set(actions).isSubset(of: Set(window.actions)) {
            switch window.schedule {
            case .oneShot(let oneShot):
                guard let start = formatter().date(from: oneShot.startsAt) else { continue }
                values.append(occurrence(window.id, start, oneShot.duration))
            case .recurring(let recurring):
                let parts = recurring.start.split(separator: ":")
                guard parts.count == 2,
                      let hour = Int(parts[0]),
                      let minute = Int(parts[1]) else { continue }
                let allowedWeekdays = Set(recurring.weekdays.map(calendarWeekday))
                let today = calendar.startOfDay(for: now)
                for offset in -8...8 {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                          allowedWeekdays.contains(calendar.component(.weekday, from: day)),
                          let searchStart = calendar.date(byAdding: .second, value: -1, to: day),
                          let start = calendar.nextDate(
                            after: searchStart,
                            matching: DateComponents(hour: hour, minute: minute, second: 0),
                            matchingPolicy: .nextTimePreservingSmallerComponents,
                            repeatedTimePolicy: .first,
                            direction: .forward
                          ),
                          calendar.isDate(start, inSameDayAs: day) else { continue }
                    values.append(occurrence(window.id, start, recurring.duration))
                }
            }
        }
        return Array(Set(values)).sorted { ($0.startsAt, $0.windowID) < ($1.startsAt, $1.windowID) }
    }

    private static func occurrence(
        _ id: String,
        _ start: Date,
        _ duration: Int
    ) -> MaintenanceWindowOccurrence {
        MaintenanceWindowOccurrence(
            windowID: id,
            startsAt: formatter().string(from: start),
            endsAt: formatter().string(from: start.addingTimeInterval(TimeInterval(duration)))
        )
    }

    private static func interval(_ occurrence: MaintenanceWindowOccurrence) -> DateInterval {
        let start = formatter().date(from: occurrence.startsAt) ?? .distantFuture
        let end = formatter().date(from: occurrence.endsAt) ?? .distantPast
        return DateInterval(start: start, end: max(start, end))
    }

    private static func formatter() -> ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    private static func calendarWeekday(_ weekday: HostwrightMaintenanceWeekday) -> Int {
        switch weekday {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }
}

import Foundation

public struct SchedulerFairnessState:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let subjectID: String
    public let projectID: String
    public let usage: ResourceVector
    public let guarantee: ResourceVector
    public let reclaimableBorrowedUsage: ResourceVector
    public let quota: ResourceVector?
    public let pendingDemand: ResourceVector
    public let starvationAgeUnits: Int64
    public let weight: Int64

    public init(
        subjectID: String,
        projectID: String,
        usage: ResourceVector = .zero,
        guarantee: ResourceVector = .zero,
        reclaimableBorrowedUsage: ResourceVector = .zero,
        quota: ResourceVector? = nil,
        pendingDemand: ResourceVector = .zero,
        starvationAgeUnits: Int64 = 0,
        weight: Int64 = 1
    ) throws {
        try SchedulerEngineContractValidation.text(subjectID, field: "subject-id")
        try SchedulerEngineContractValidation.text(projectID, field: "project-id")
        guard weight > 0, weight <= SchedulerEngineLimits.absoluteMaxWeight else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "fairness-weight",
                value: weight
            )
        }
        guard reclaimableBorrowedUsage.fits(in: usage) else {
            throw SchedulerEngineValidationError.invalidDecision(
                "fairness-borrowed-usage-exceeds-usage"
            )
        }
        guard starvationAgeUnits >= 0,
              starvationAgeUnits <= SchedulerEngineLimits.absoluteMaxWeight else {
            throw SchedulerEngineValidationError.invalidValue(
                field: "starvation-age",
                value: starvationAgeUnits
            )
        }
        if let quota, !usage.fits(in: quota) {
            throw SchedulerEngineValidationError.invalidDecision(
                "fairness-usage-exceeds-quota"
            )
        }
        if let quota, !guarantee.fits(in: quota) {
            throw SchedulerEngineValidationError.invalidDecision(
                "fairness-guarantee-exceeds-quota"
            )
        }
        self.subjectID = subjectID
        self.projectID = projectID
        self.usage = usage
        self.guarantee = guarantee
        self.reclaimableBorrowedUsage = reclaimableBorrowedUsage
        self.quota = quota
        self.pendingDemand = pendingDemand
        self.starvationAgeUnits = starvationAgeUnits
        self.weight = weight
    }

    private enum CodingKeys: String, CodingKey {
        case subjectID
        case projectID
        case usage
        case guarantee
        case reclaimableBorrowedUsage
        case quota
        case pendingDemand
        case starvationAgeUnits
        case weight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            subjectID: container.decode(String.self, forKey: .subjectID),
            projectID: container.decode(String.self, forKey: .projectID),
            usage: container.decodeIfPresent(ResourceVector.self, forKey: .usage) ?? .zero,
            guarantee: container.decodeIfPresent(ResourceVector.self, forKey: .guarantee) ?? .zero,
            reclaimableBorrowedUsage: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .reclaimableBorrowedUsage
            ) ?? .zero,
            quota: container.decodeIfPresent(ResourceVector.self, forKey: .quota),
            pendingDemand: container.decodeIfPresent(
                ResourceVector.self,
                forKey: .pendingDemand
            ) ?? .zero,
            starvationAgeUnits: container.decodeIfPresent(
                Int64.self,
                forKey: .starvationAgeUnits
            ) ?? 0,
            weight: container.decodeIfPresent(Int64.self, forKey: .weight) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subjectID, forKey: .subjectID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(usage, forKey: .usage)
        try container.encode(guarantee, forKey: .guarantee)
        try container.encode(reclaimableBorrowedUsage, forKey: .reclaimableBorrowedUsage)
        try container.encodeIfPresent(quota, forKey: .quota)
        try container.encode(pendingDemand, forKey: .pendingDemand)
        try container.encode(starvationAgeUnits, forKey: .starvationAgeUnits)
        try container.encode(weight, forKey: .weight)
    }
}

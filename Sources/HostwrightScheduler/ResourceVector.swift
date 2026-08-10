import Foundation

public struct ResourceVector:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let zero = ResourceVector(validatedValues: [:])

    public let values: [String: Int64]

    public init(_ values: [String: Int64]) throws {
        var canonical: [String: Int64] = [:]
        canonical.reserveCapacity(values.count)

        for (resource, value) in values {
            let canonicalResource = try SchedulerCanonicalization.resourceName(resource)
            guard value >= 0 else {
                throw SchedulerValidationError.negativeResourceValue(
                    resource: canonicalResource,
                    value: value
                )
            }
            if value > 0 {
                canonical[canonicalResource] = value
            }
        }

        self.values = canonical
    }

    public var resourceNames: [String] {
        values.keys.sorted()
    }

    public var isEmpty: Bool {
        values.isEmpty
    }

    public subscript(resource: String) -> Int64 {
        values[resource] ?? 0
    }

    public func adding(_ other: ResourceVector) throws -> ResourceVector {
        let names = Set(resourceNames).union(other.resourceNames).sorted()
        var result: [String: Int64] = [:]
        result.reserveCapacity(names.count)

        for resource in names {
            let (sum, overflow) = self[resource].addingReportingOverflow(other[resource])
            guard !overflow else {
                throw SchedulerValidationError.arithmeticOverflow(resource: resource)
            }
            if sum > 0 {
                result[resource] = sum
            }
        }

        return ResourceVector(validatedValues: result)
    }

    public func subtracting(_ other: ResourceVector) throws -> ResourceVector {
        let names = Set(resourceNames).union(other.resourceNames).sorted()
        var result: [String: Int64] = [:]
        result.reserveCapacity(names.count)

        for resource in names {
            let left = self[resource]
            let right = other[resource]
            guard left >= right else {
                throw SchedulerValidationError.arithmeticUnderflow(resource: resource)
            }
            let difference = left - right
            if difference > 0 {
                result[resource] = difference
            }
        }

        return ResourceVector(validatedValues: result)
    }

    public func remaining(after allocation: ResourceVector) throws -> ResourceVector {
        try subtracting(allocation)
    }

    public func fits(in capacity: ResourceVector) -> Bool {
        resourceNames.allSatisfy { self[$0] <= capacity[$0] }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SchedulerDynamicCodingKey.self)
        var values: [String: Int64] = [:]
        values.reserveCapacity(container.allKeys.count)
        for key in container.allKeys {
            values[key.stringValue] = try container.decode(Int64.self, forKey: key)
        }
        try self.init(values)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SchedulerDynamicCodingKey.self)
        for resource in resourceNames {
            try container.encode(
                values[resource],
                forKey: SchedulerDynamicCodingKey(stringValue: resource)!
            )
        }
    }

    private init(validatedValues: [String: Int64]) {
        self.values = validatedValues
    }
}

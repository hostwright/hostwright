import Foundation

public enum ControlStreamGlobalBudgetError: Error, Equatable, Sendable {
  case globalLimit
  case subjectLimit
}

public final class ControlStreamGlobalBudget: @unchecked Sendable {
  public static let maximumGlobalStreams = 256
  public static let maximumSubjectStreams = 64

  private let lock = NSLock()
  private var owners: [String: String] = [:]
  private var subjectCounts: [String: Int] = [:]

  public init() {}

  public func acquire(key: String, subjectID: String) throws {
    try lock.withLock {
      guard owners[key] == nil else { return }
      guard owners.count < Self.maximumGlobalStreams else {
        throw ControlStreamGlobalBudgetError.globalLimit
      }
      guard subjectCounts[subjectID, default: 0] < Self.maximumSubjectStreams else {
        throw ControlStreamGlobalBudgetError.subjectLimit
      }
      owners[key] = subjectID
      subjectCounts[subjectID, default: 0] += 1
    }
  }

  public func release(key: String) {
    lock.withLock {
      guard let subjectID = owners.removeValue(forKey: key) else { return }
      let remaining = subjectCounts[subjectID, default: 1] - 1
      if remaining == 0 { subjectCounts.removeValue(forKey: subjectID) }
      else { subjectCounts[subjectID] = remaining }
    }
  }

  public var activeCount: Int { lock.withLock { owners.count } }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

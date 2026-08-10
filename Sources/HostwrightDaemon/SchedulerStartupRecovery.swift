import Foundation
import HostwrightState

public enum SchedulerRuntimeObservationState: String, Equatable, Sendable {
  case present
  case absent
  case unknown
}

/// A runtime observation is evidence, not a desired state.  An unknown
/// observation is deliberately retained as durable scheduler authority.
public struct SchedulerRuntimeObservation: Equatable, Sendable {
  public let state: SchedulerRuntimeObservationState
  public let evidenceDigest: String

  public init(
    state: SchedulerRuntimeObservationState,
    evidenceDigest: String
  ) throws {
    guard evidenceDigest.count == 64,
          evidenceDigest.unicodeScalars.allSatisfy({ scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
          }) else {
      throw SchedulerAdmissionError.invalidEvidence("runtime-observation-digest")
    }
    self.state = state
    self.evidenceDigest = evidenceDigest
  }
}

public struct SchedulerStartupRecoveryReport: Equatable, Sendable {
  public let examinedReservations: Int
  public let committedReservations: Int
  public let releasedReservations: Int
  public let retainedReservations: Int
  public let examinedPreemptionIntents: Int
  public let recoveredPreemptionIntents: Int
  public let retainedPreemptionIntents: Int

  public init(
    examinedReservations: Int,
    committedReservations: Int,
    releasedReservations: Int,
    retainedReservations: Int,
    examinedPreemptionIntents: Int,
    recoveredPreemptionIntents: Int,
    retainedPreemptionIntents: Int
  ) {
    self.examinedReservations = examinedReservations
    self.committedReservations = committedReservations
    self.releasedReservations = releasedReservations
    self.retainedReservations = retainedReservations
    self.examinedPreemptionIntents = examinedPreemptionIntents
    self.recoveredPreemptionIntents = recoveredPreemptionIntents
    self.retainedPreemptionIntents = retainedPreemptionIntents
  }
}

/// Reconciles only scheduler rows that can safely be completed from an
/// authoritative runtime observation.  This coordinator never uses lease
/// expiry as evidence and never executes a runtime mutation.
public struct SchedulerStartupRecoveryCoordinator {
  public typealias RuntimeObservationProvider = @Sendable (
    SchedulerReservationRecord
  ) throws -> SchedulerRuntimeObservation

  private let repository: SchedulerAdmissionRepository
  private let observe: RuntimeObservationProvider
  private let now: @Sendable () -> String

  public init(
    repository: SchedulerAdmissionRepository,
    observe: @escaping RuntimeObservationProvider,
    now: @escaping @Sendable () -> String
  ) {
    self.repository = repository
    self.observe = observe
    self.now = now
  }

  public func recover() throws -> SchedulerStartupRecoveryReport {
    // Validate every recoverable preemption join before touching ordinary
    // reservations. A forged or incomplete intent must not let its victim be
    // released by the generic reservation pass.
    let recoveries = try repository.recoverablePreemptionIntents()
    let reservations = try repository.recoverableReservations()
    var committedReservations = 0
    var releasedReservations = 0
    var retainedReservations = 0

    for reservation in reservations {
      guard let observation = try? observe(reservation) else {
        retainedReservations += 1
        continue
      }
      switch observation.state {
      case .present:
        guard reservation.status == .pending else {
          retainedReservations += 1
          continue
        }
        do {
          _ = try repository.commit(
            reservationID: reservation.reservationID,
            expectedToken: reservation.fencingToken,
            updatedAt: now()
          )
          committedReservations += 1
        } catch {
          retainedReservations += 1
        }
      case .absent:
        do {
          _ = try repository.release(
            reservationID: reservation.reservationID,
            expectedToken: reservation.fencingToken,
            evidence: .verifiedRuntimeAbsence(
              evidenceDigest: observation.evidenceDigest,
              verifiedAt: now()
            )
          )
          releasedReservations += 1
        } catch {
          // A stale token or an incomplete state transition is a safe hold.
          retainedReservations += 1
        }
      case .unknown:
        retainedReservations += 1
      }
    }

    var recoveredPreemptionIntents = 0
    var retainedPreemptionIntents = 0
    for recovery in recoveries {
      let intent = recovery.intent
      switch intent.status {
      case .fenced:
        if try recoverFencedIntent(
          recovery,
          committedReservations: &committedReservations,
          releasedReservations: &releasedReservations
        ) {
          recoveredPreemptionIntents += 1
        } else {
          retainedPreemptionIntents += 1
        }
      case .proposed, .fencePending:
        if try recoverUnfencedIntent(
          recovery,
          releasedReservations: &releasedReservations
        ) {
          recoveredPreemptionIntents += 1
        } else {
          retainedPreemptionIntents += 1
        }
      case .applied, .recovered, .rejected:
        continue
      }
    }

    return SchedulerStartupRecoveryReport(
      examinedReservations: reservations.count,
      committedReservations: committedReservations,
      releasedReservations: releasedReservations,
      retainedReservations: retainedReservations,
      examinedPreemptionIntents: recoveries.count,
      recoveredPreemptionIntents: recoveredPreemptionIntents,
      retainedPreemptionIntents: retainedPreemptionIntents
    )
  }

  private func recoverFencedIntent(
    _ recovery: SchedulerPreemptionRecoveryRecord,
    committedReservations: inout Int,
    releasedReservations: inout Int
  ) throws -> Bool {
    let intent = recovery.intent
    guard let targetSnapshot = recovery.targetReservation,
          let target = try repository.reservation(id: targetSnapshot.reservationID) else {
      return false
    }
    if target.status == .released {
      do {
        _ = try repository.transitionPreemptionIntent(
          intentID: intent.intentID,
          expectedRecordDigest: intent.recordDigest,
          to: .recovered,
          updatedAt: now()
        )
        return true
      } catch {
        return false
      }
    }
    guard let observation = try? observe(target) else {
      return false
    }
    switch observation.state {
    case .present:
      if target.status == .pending {
        do {
          _ = try repository.commit(
            reservationID: target.reservationID,
            expectedToken: target.fencingToken,
            updatedAt: now()
          )
          committedReservations += 1
        } catch {
          return false
        }
      }
      guard let committed = try repository.reservation(id: target.reservationID),
            committed.status == .committed else {
        return false
      }
      do {
        _ = try repository.transitionPreemptionIntent(
          intentID: intent.intentID,
          expectedRecordDigest: intent.recordDigest,
          to: .applied,
          updatedAt: now()
        )
        return true
      } catch {
        return false
      }
    case .absent:
      do {
        _ = try repository.release(
          reservationID: target.reservationID,
          expectedToken: target.fencingToken,
          evidence: .verifiedRuntimeAbsence(
            evidenceDigest: observation.evidenceDigest,
            verifiedAt: now()
          )
        )
        releasedReservations += 1
        _ = try repository.transitionPreemptionIntent(
          intentID: intent.intentID,
          expectedRecordDigest: intent.recordDigest,
          to: .recovered,
          updatedAt: now()
        )
        return true
      } catch {
        return false
      }
    case .unknown:
      return false
    }
  }

  private func recoverUnfencedIntent(
    _ recovery: SchedulerPreemptionRecoveryRecord,
    releasedReservations: inout Int
  ) throws -> Bool {
    let intent = recovery.intent
    var allVictimsAbsent = true
    for reservationSnapshot in recovery.victimReservations {
      guard let reservation = try repository.reservation(
        id: reservationSnapshot.reservationID
      ) else {
        allVictimsAbsent = false
        continue
      }
      guard reservation.status.reservesCapacity else { continue }
      guard let observation = try? observe(reservation) else {
        allVictimsAbsent = false
        continue
      }
      switch observation.state {
      case .absent:
        do {
          _ = try repository.release(
            reservationID: reservation.reservationID,
            expectedToken: reservation.fencingToken,
            evidence: .verifiedRuntimeAbsence(
              evidenceDigest: observation.evidenceDigest,
              verifiedAt: now()
            )
          )
          releasedReservations += 1
        } catch {
          allVictimsAbsent = false
        }
      case .present, .unknown:
        allVictimsAbsent = false
      }
    }
    guard allVictimsAbsent else { return false }
    let status: SchedulerPreemptionIntentStatus =
      intent.status == .proposed ? .rejected : .recovered
    do {
      _ = try repository.transitionPreemptionIntent(
        intentID: intent.intentID,
        expectedRecordDigest: intent.recordDigest,
        to: status,
        updatedAt: now()
      )
      return true
    } catch {
      return false
    }
  }
}

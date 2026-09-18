import Foundation

struct DistributionTerminalCleanup: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let journal: DistributionLifecycleJournal
    let completedStatus: DistributionInstallationStatus
    let adoptedOwnerReceiptSHA256: String
    let originalDescriptorSHA256: String
    let deleteTransactionRelativePaths: [String]
    let retainTransactionRelativePaths: [String]

    static func dispositions(_ journal: DistributionLifecycleJournal) -> (delete: [String], retain: [String]) {
        let base = "\(DistributionLayout.lifecycleDirectoryName)/\(DistributionLayout.lifecycleTransactionsDirectoryName)/"
        if journal.checkpoint == .compensationPublished {
            return ([base + journal.operationID], journal.priorStatus?.rollbackOperationID.map { [base + $0] } ?? [])
        }
        switch journal.operation {
        case .upgrade:
            return (journal.priorStatus?.rollbackOperationID.map { $0 == journal.operationID ? [] : [base + $0] } ?? [], [base + journal.operationID])
        case .rollback:
            return ([base + journal.operationID] + (journal.authorizedRollbackOperationID.map { [base + $0] } ?? []), [])
        case .repair, .install:
            return ([base + journal.operationID] + (journal.priorStatus?.rollbackOperationID.map { [base + $0] } ?? []), [])
        case .uninstall: return ([], [])
        }
    }

    func validate() throws {
        try journal.validate()
        try completedStatus.validate()
        let expected = Self.dispositions(journal)
        let isPrior = journal.checkpoint == .compensationPublished
        guard schemaVersion == 1, journal.operation != .uninstall,
              isPrior || journal.checkpoint == .statusPublished,
              originalDescriptorSHA256 == journal.ownerStateDescriptorSHA256,
              Self.isDigest(originalDescriptorSHA256), Self.isDigest(adoptedOwnerReceiptSHA256),
              completedStatus.prefix == journal.prefix,
              completedStatus.installationID == journal.priorStatus?.installationID,
              deleteTransactionRelativePaths == expected.delete,
              retainTransactionRelativePaths == expected.retain,
              Set(expected.delete).isDisjoint(with: Set(expected.retain)) else {
            throw DistributionError.lifecycleFailed("terminal cleanup proof has inconsistent transaction bindings")
        }
        if isPrior {
            guard completedStatus == journal.priorStatus else {
                throw DistributionError.lifecycleFailed("terminal cleanup proof differs from restored prior status")
            }
        } else {
            guard completedStatus.generation == (journal.priorStatus?.generation ?? 0) + 1,
                  completedStatus.installedManifest == journal.toManifest,
                  completedStatus.stateDatabasePath == journal.priorStatus?.stateDatabasePath,
                  completedStatus.service == journal.serviceBefore,
                  completedStatus.rollbackOperationID == (journal.operation == .upgrade ? journal.operationID : nil) else {
                throw DistributionError.lifecycleFailed("terminal cleanup proof differs from published status")
            }
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}

import HostwrightRuntime
import HostwrightState

@_spi(Phase03Qualification)
public enum RuntimeProviderMigrationJournalFactory {
    public static func sqlite(
        store: SQLiteStateStore,
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest
    ) -> any RuntimeProviderMigrationJournaling {
        SQLiteRuntimeProviderMigrationJournal(
            store: store,
            plan: plan,
            request: request
        )
    }
}

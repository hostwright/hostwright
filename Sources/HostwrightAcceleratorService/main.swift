import Darwin
import HostwrightAcceleratorXPC
import HostwrightCore
import HostwrightState

do {
    let resolution = try HostwrightLocalPathResolver.resolve()
    let store = SQLiteStateStore(
        configuration: StateStoreConfiguration(localPathResolution: resolution)
    )
    try store.migrate()
    let replayStore = AcceleratorStateXPCReplayStore(store: store)
    AcceleratorXPCServiceRuntime.run(durableReplayStore: replayStore)
} catch {
    Darwin.exit(78)
}

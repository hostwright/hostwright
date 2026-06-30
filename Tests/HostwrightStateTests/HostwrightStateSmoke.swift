import HostwrightState

let hostwrightStateSmoke: Void = {
    let store = SQLiteStateStore(path: "/tmp/hostwright.sqlite")
    _ = store
}()


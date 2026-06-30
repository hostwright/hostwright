import HostwrightCore

let hostwrightCoreSmoke: Void = {
    precondition(HostwrightIdentity.projectName == "Hostwright")
    precondition(HostwrightIdentity.cliName == "hostwright")
    precondition(HostwrightIdentity.daemonName == "hostwrightd")
    precondition(HostwrightIdentity.manifestFileName == "hostwright.yaml")
    precondition(HostwrightIdentity.domain == "hostwright.dev")
    precondition(HostwrightIdentity.developmentVersion == "0.0.0-dev")

    let diagnostics = CompatibilityGate.evaluate(
        PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64")
    )
    precondition(diagnostics.map(\.code) == [.unsupportedArchitecture, .unsupportedMacOSVersion])
}()

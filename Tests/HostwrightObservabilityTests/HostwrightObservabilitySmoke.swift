import HostwrightObservability

let hostwrightObservabilitySmoke: Void = {
    let redacted = SecretRedactor.redact(
        value: "token=abc123",
        secretKeys: ["abc123"]
    )

    precondition(redacted == "token=[REDACTED]")
}()


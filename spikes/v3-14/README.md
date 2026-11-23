# V3-14 Local Network and TLS exporter spike

This standalone macOS Swift package has no external dependencies.

```sh
swift build --package-path spikes/v3-14
"$(swift build --package-path spikes/v3-14 --show-bin-path)/v314-probe" exporter
```

The host probe uses Network.framework over TCP on 127.0.0.1. Both peers require TLS 1.3 and pin the other's ephemeral certificate. It creates a private temporary keychain, verifies that each permanent P-256 private key cannot be exported, and compares the two 32-byte outputs of `sec_protocol_metadata_create_secret`. It prints only the comparison and lengths. It removes the test keychain on completion.

If the verified TLS session supplies no matching exporter, D8 uses a MAC over the transcript including both certificate SHA-256 fingerprints. A failed TLS handshake is inconclusive about exporter support.

The VM experiment measures consent from a user LaunchAgent over an on-link connection. See the [VM runbook](vm/RUNBOOK.md) and [results template](vm/RESULTS.md).

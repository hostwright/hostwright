# Apple container integration

Hostwright supports the declared capabilities of Apple `container` 1.0.0 and 1.1.0 through Runtime Provider API v2. The native Containerization 0.35.0 provider runs in a separate authenticated helper. See [runtime providers](runtime-adapter.md) and the [compatibility matrix](../reference/compatibility.md).

## CLI provider

`RuntimeExecutableResolver` validates the executable and its path. `AppleContainerCommand` constructs versioned argument vectors; `SecureRuntimeProcessRunner` enforces command policy, timeouts, cancellation, bounded output, and redaction. The CLI, daemon, state store, and reconciler do not invoke Apple container independently.

Versioned codecs parse structured output. Unsupported versions, malformed responses, conflicting identities, and unknown required values fail before mutation. Names and labels help locate resources; current UUID-backed ownership and generation records authorize changes.

## Lifecycle and capability checks

The lifecycle coordinator composes provider operations into reviewed plans. Each mutation requires current capability, ownership, policy, and authority checks, a durable operation record, and an observed result. Ambiguous effects require observation or recovery before retry.

Image, network, interactive, and lifecycle operations are available only when the selected provider advertises them. The Containerization helper requires pre-existing local images and exposes a smaller subset than the CLI provider. Neither provider authorizes unmanaged deletion or global cleanup.

Add runtime behavior only with recorded version-specific conformance and failure tests. Document unsupported combinations in [compatibility](../reference/compatibility.md) and [limitations](../reference/limitations.md).

# v0.0.2 Golden Contracts

These files are executable compatibility fixtures for the contracts locked in Phase 01. Tests decode them with production types/parsers; changing a file or model requires a reviewed contract decision, migration/compatibility update, and refreshed consumer evidence.

- `versions.json`: product/release and Manifest, Control API, Runtime Provider API, plugin ABI, and state schema versions.
- `manifest.yaml`: smallest accepted explicit Manifest v2 application.
- `control-plan-request.json`: smallest accepted Control API v2 plan request.
- `control-plan-response.json`: stable Control API v2 response envelope.
- `runtime-provider-metadata.json`: Runtime Provider API v2 capability metadata.
- `runtime-provider-capabilities.json`: canonical Runtime Provider API v2 capability-snapshot grammar.
- `plugin-declaration.json`: plugin ABI v1 reviewed-local declaration supported by the current narrow extension boundary.

Runtime Provider API v2 uses the stable provider IDs `apple-container-cli` and `apple-containerization`. Its metadata and capability-snapshot codecs are locked by production-decoded goldens. The Containerization boundary uses helper protocol v1 with bounded length-prefixed canonical JSON frames; protocol, replay, truncation, overflow, and version-refusal behavior is locked by executable contract tests rather than a placeholder wire fixture.

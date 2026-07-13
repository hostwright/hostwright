# v0.0.2 Golden Contracts

These files are executable compatibility fixtures for the contracts locked in Phase 01. Tests decode them with production types/parsers; changing a file or model requires a reviewed contract decision, migration/compatibility update, and refreshed consumer evidence.

- `versions.json`: product/release and Manifest, Control API, Runtime Provider API, plugin ABI, and state schema versions.
- `manifest.yaml`: smallest accepted explicit Manifest v2 application.
- `control-plan-request.json`: smallest accepted Control API v2 plan request.
- `control-plan-response.json`: stable Control API v2 response envelope.
- `runtime-provider-metadata.json`: Runtime Provider API v2 capability metadata.
- `plugin-declaration.json`: plugin ABI v1 reviewed-local declaration supported by the current narrow extension boundary.

Runtime Provider API v2 is currently a typed in-process contract; its version and metadata codec are locked by production-decoded goldens. Phase 03 adds the versioned out-of-process Containerization protocol goldens only when that protocol is implemented—no placeholder wire schema is claimed here.

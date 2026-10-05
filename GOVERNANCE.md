# Governance

The maintainer sets release scope and approves changes to dependencies, licensing, public contracts, security boundaries, and distribution. Contributors can propose changes through issues and pull requests.

## Review

Changes to runtime mutation, resource ownership, state migrations, secrets, diagnostics, and installers require review of their failure and recovery behavior. Release changes must bind their claims to the source and artifacts tested.

Use design records for consequential architecture or compatibility decisions. Keep routine fixes and documentation corrections in their pull requests. The [issue manifest](docs/roadmap/v0.0.2/issues.json) records the release workstreams and their required or deferred disposition.

## Releases

The maintainer approves release tags, publication, package channels, and support claims. Qualification must pass on the exact release commit and version. Public tags and published artifacts remain immutable; exceptional removal requires a separate reviewed action.

Required roadmap issues close with verified evidence. Deferred issues close as `not_planned` under the recorded scope decision. Parents close after their children meet the corresponding requirements. The [release process](docs/release/RELEASE_PROCESS.md) defines the checks and approval sequence.

## Security and support

Follow [SECURITY.md](SECURITY.md) for sensitive reports. Public issues must omit credentials, exploit details, private paths, and raw databases. Hostwright provides local diagnostics and recovery tools; it offers no production support SLA or hosted diagnostics service.

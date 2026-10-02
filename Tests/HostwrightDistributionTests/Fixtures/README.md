# Published dev.12 installation fixtures

These records came from the preserved installation of `0.0.2-dev.12`, source
`71414005104933d8ee3591e8c91bc831bce2e2a2`, during the actual package-upgrade
qualification on 2026-10-02.

`dev12-install-manifest.json` is byte-for-byte the installed ownership manifest.
Its SHA-256 is `945ac49fcc5f35433e248de739540e931e79782a505841b1d164901757980f86`.
The original source emitted install schema 2 for this seven-file payload.

`dev12-installation-status.json` preserves the captured lifecycle status except
that its installation UUID is replaced with
`11111111-1111-4111-8111-111111111111`. The original status SHA-256 is
`fde35f0181c3ce70b9ef2cd2ba0ec63f344cb92ed3c48c2281ff8fc9f0e68051`.
Its nested ownership manifest is unchanged. This covers the validation entry
point used by `export-state-challenge`, including the package-origin fields.

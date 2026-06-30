# Naming Decision Record

## Decision

Hostwright is the canonical public project name.

## Context

The project source material was originally written under the Orchard codename. That name now remains only as historical source material. Public-facing code, docs, package names, CLI names, daemon names, schema names, and examples must use Hostwright.

## Rationale

Hostwright describes a tool that shapes and maintains desired state on the local host. It avoids Kubernetes, Docker, cloud, fleet, and botanical naming lanes, and it maps cleanly to the CLI name `hostwright`.

## Consequences

- Public docs use Hostwright.
- The CLI is `hostwright`.
- The daemon is `hostwrightd`.
- The manifest is `hostwright.yaml`.
- The project domain is `hostwright.dev`.
- Historical source documents retain their original filenames in preservation folders.


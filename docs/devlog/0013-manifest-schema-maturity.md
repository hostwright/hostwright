# Phase 13: Manifest Schema Maturity

## Summary

Phase 13 aligns the restricted manifest parser, schema file, examples, docs, and tests around one explicit Hostwright manifest subset.

## What Changed

- Added optional `version: 1` manifest parsing and model storage.
- Treats omitted version as legacy alpha version 1 input.
- Rejects explicit older or newer manifest versions; no automatic upgrade or downgrade conversion is implemented.
- Improved unsupported-field diagnostics for top-level, service, health, restart, Kubernetes-style, and Compose-style fields.
- Tightened validation for unsafe environment keys, empty service command tokens, and host-root or parent-traversal mount sources.
- Updated examples and schema alignment coverage, including a supported app-suite example.

## Rejected Paths

- No YAML dependency.
- No general YAML parser claim.
- No Compose parity.
- No Kubernetes-style `apiVersion`/`kind` compatibility.
- No registry, image availability, or network validation.
- No runtime mutation changes.

## Verification

Phase 13 adds XCTest coverage for version policy, unsupported fields, unsafe untrusted-manifest shapes, schema/example alignment, and generated starter manifest validity. Full local verification is required before PR.

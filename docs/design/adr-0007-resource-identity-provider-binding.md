# ADR 0007: Resource UUIDs and Project-Generation Provider Binding

Status: Accepted for v0.0.2

## Context

Apple resource names are mutable presentation values and may collide across projects, upgrades, imported state, or runtime providers. Hostwright also supports both Apple `container` CLI and a direct Containerization helper. Allowing either provider to mutate a project opportunistically makes recovery and ownership ambiguous.

## Decision

- Every Hostwright resource has a Hostwright UUID. Runtime names, labels, paths, addresses, and external IDs are attributes.
- Legacy state receives deterministic UUIDs derived from the resource kind and stable legacy identity so repeated migration is idempotent. An unambiguous owned instance may align with its desired-service UUID; duplicate legacy instances use their ownership record IDs so collisions cannot collapse distinct resources.
- Every desired project generation records one mutation provider and monotonically increasing provider generation.
- A provider may observe resources it does not own, but may mutate only a project generation explicitly bound to it.
- Changing provider is a first-class fenced migration: stop admission, record intent, verify source observation, transfer or recreate resources according to capability, verify postconditions, then advance the generation.
- Ownership records bind resource UUID, project UUID/generation, provider, provider generation, runtime identifier, resource generation, and fencing token.
- Names alone never authorize start, stop, update, attach, or deletion.

## Failure and Threat Model

- A crash during provider migration leaves a durable checkpoint and does not release the old fencing token until recovery decides the next safe step.
- A stale provider or node cannot mutate after a newer fencing token is committed.
- Missing, duplicated, mismatched, or unverified identity blocks mutation and garbage collection.
- Unmanaged resources can be reported or quarantined but are never silently adopted or deleted.
- Deterministic legacy UUIDs are identifiers, not authentication tokens or secrets.

## Consequences

State schema v7 adds resource UUID, manifest version, mutation-provider, provider-generation, resource-generation, and fencing fields. Runtime Provider API v2 and every lifecycle/storage/network/cluster workstream must carry the identity tuple. The extra state and migration ceremony are accepted because exact recovery and cleanup matter more than name-based convenience.

## Verification

Unit and Phase 03 live migration evidence cover idempotent backfill, UUID stability, collision handling, provider-binding refusal, same-provider generation updates, stale fencing, CLI-to-helper and helper-to-CLI migration, checkpoint recovery, compensation, future schema refusal, and redaction. Phase 11 owns multi-Mac cluster fencing evidence.

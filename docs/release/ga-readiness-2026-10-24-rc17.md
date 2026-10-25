# GA readiness — RC.17 preparation, October 24, 2026

Current source prepares `0.0.2-rc.17`. No supported RC or GA has been published.
Manifest v3, Control API 2.2, state schema v24 and the single-Mac scope remain unchanged.

## Bounded port-reservation repair

The RC.16 recovery run stopped the old container during a same-port update, then
rejected the replacement because the old durable host-port reservation remained
active. The update compensated and restored the previous workload; it did not
reach the intended interruption boundary or qualify recovery.

[The repair](https://github.com/hostwright/hostwright/pull/418) transfers
reservations atomically only after the exact predecessor is proven quiesced under
the persisted update plan. Unrelated owners, stale authority and unavailable
sockets remain conflicts. Rollback reacquires reservations before restarting the
old container. If retirement already occurred, it removes the candidate before
recreating the predecessor and requires durable inverse-creation evidence.
Reservation and activation writes validate the exact finite operation lease in
the transaction. The repair changes no runtime payload pins or compatibility schema.

The focused repair has 85 unique passing tests covering reservation handoff,
authority refusal, atomic storage, rollback ordering, lifecycle probes and
SIGKILL recovery. Independent review found no unresolved findings in that repair.
These checks do not qualify signed RC.17 artifacts. The RC.16 source, signed stage,
partial qualification and failed recovery retain their original bindings. The
[RC.16 preparation record](ga-readiness-2026-10-22-rc16.md) remains historical.

## SQLite qualification and website audit repair

The RC.17 ThreadSanitizer base completed with one assertion failure: its
symlink-swap fixture encountered `EEXIST` at iteration 457. No ThreadSanitizer
race diagnostic was recorded. That run did not qualify the sanitizer gate.

The fixture now exchanges the database with a preseeded symlink atomically,
without the previous missing-path interval. It retains the 1,000 attack
iterations, 500 schema reads, sentinel preservation, error and final-schema
assertions. A separate missing-database test checks that read-only schema
validation refuses the displaced database without recreating or changing it.
The creator of the prior `EEXIST` path remains unconfirmed; this is a fixture
repair, not a claim that a production SQLite security defect was established.

[Website PR #32](https://github.com/hostwright/hostwright.dev/pull/32) merged the
readiness corrections and patched only Undici and Zod in both dependency locks.
Both packages passed check, build, links and `npm audit --audit-level=high`;
merged-main CI and deployment passed and the public readiness pages were checked.
Both audits have zero high or critical findings; lower-severity findings remain.
These results do not execute signed CLI, Compose or desktop quickstarts.

## Remaining closing gates

1. The port-reservation repair is merged. Finish the bounded SQLite-fixture
   repair after current-head checks pass, then freeze clean replacement source
   before candidate qualification. Reuse unchanged input evidence only within its
   verified scope. Candidate-bound results require the exact new source, version
   and staged inventory; focused repair checks are not full qualification.
2. Complete source regression and both full sanitizer suites, parser fuzzing,
   security and independent review. Complete provider conformance and ten cycles
   for each supported lane, the 30-minute soak, all eight recovery operations,
   all twelve signed VM lifecycle operations, and live public quickstarts and
   accessibility. Issues #271, #277, #278 and #279 remain open until verified.
3. After RC acceptance, make one reviewed final `0.0.2` version change. Qualify
   the exact signed final bytes, obtain protected acceptance, publish, and verify
   public downloads and the vendor tap before closing #281.
4. Submit the cask against those public stable bytes. Keep #282, #283 and #284
   open until official Homebrew acceptance and fresh-machine
   `brew install hostwright` pass. Pending review triggers no retesting.

One additional bounded round for the SQLite qualification fixture and website
audit was authorized after 8 p.m. Eastern. Start no further repair round. Stop at
11:59 p.m. Eastern on October 24 with completed GA or a precise unfinished-gate
report. Missing
credentials, lab capacity, signing failure, ungranted publication authority or
Homebrew review remain blockers. See the [acceptance contract](../reference/release-promotion.md).

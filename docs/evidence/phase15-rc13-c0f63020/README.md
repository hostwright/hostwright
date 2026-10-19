# RC.13 source, sanitizer and fuzz results

Frozen source [`c0f63020`](https://github.com/hostwright/hostwright/commit/c0f63020f1c4187623d48d9c0770679b8b0de0d1), version `0.0.2-rc.13`, passed **3,556 unique tests in each of SOURCE, AddressSanitizer and ThreadSanitizer**, with zero failures or skips in each completed aggregate.

Each aggregate combines 3,546 actual base passes with ten unique routed live passes. The additional permission-restoration execution is excluded from the unique count. Actual allowed, denied and restored Local Network controls passed, all 48 original host permission entries were restored, and each qualification VM stopped naturally with unchanged configuration.

The [derived progress summary](qualification-progress-summary.json) binds the complete matrix outputs, gate receipts and independent outcome reviews by SHA-256. All six parser/protocol fuzz targets passed about 302 seconds each, with 5,080,658 timed executions, retained initial/final corpus replay and no crash artifacts.

This publishes a summary and hashes, not the underlying raw evidence export. The qualification packet retains raw logs, ownership and cleanup records, original failures, and independent reviews. Complete child at-exit diagnostics remain unclaimed.

The [exact-source runtime producer](https://github.com/hostwright/hostwright/actions/runs/39171521610) passed. The [trusted staging run](https://github.com/hostwright/hostwright/actions/runs/39294412896) received protected release approval; attempt 1 was cancelled during the operator-requested meeting pause before signing. Signed staging must complete before installed-artifact qualification. These results do not close Phase 15 or establish RC, GA or official Homebrew acceptance. See the [current readiness record](../../release/ga-readiness-2026-10-19.md).

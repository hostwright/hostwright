# RC.12 supported source and sanitizer matrices

The frozen source is [`aa8586a1`](https://github.com/hostwright/hostwright/commit/aa8586a1ccc7887f7ae09dcccdc32bf13c27c705), version `0.0.2-rc.12`.
The [derived source matrix summary](source-matrix-summary.json) records **3,554 unique passing tests**: 3,493 XCTest and 61 Swift Testing cases, with no failures or skips in the completed aggregate.

The base actually passed 3,483 XCTest and 61 Swift Testing cases and skipped ten routed live cases. Ten fresh, unique live executions complete the aggregate; none of the skipped results is counted as a pass. The permission-restoration repeat is excluded from the unique count. The initial failed TLS execution remains retained, and only its successful retry is credited.

The original verifier output, independent review and raw execution records remain in the qualification packet. This summary publishes their hashes and individual live-case outcomes; it is not an export of those raw records. Source coverage does not establish sanitizer, signed-installation, RC, GA or official Homebrew acceptance.

The [runtime and fuzz summary](runtime-and-fuzz-summary.json) records the exact authenticated runtime archive and six fresh five-minute fuzz targets with retained corpus replay. Independent review verified their raw bindings and cleanup. Signed-artifact acceptance remains open. The original hosted payload mismatch is retained alongside its passing retry.

The [qualification progress summary](qualification-progress-summary.json) records the failed ASan base (3,482 XCTest passes, one failure, and 61 Swift Testing passes), its original receipt/log hashes, and the independently verified production-builder comparison. Both production builds matched all nine executable payloads. The original hosted distribution failure remains separate. Attempt 2 reran only that failed shard and passed all 54 tests; GitHub carries forward the original successful release/live executions. No full sanitizer or release acceptance is claimed.

## Supported sanitizer test coverage — October 16

The [sanitizer coverage summary](sanitizer-coverage-summary.json) records **3,554 unique passing identities in each of ASan and TSan** on the same frozen source. Each completed aggregate combines 3,483 XCTest and 61 Swift Testing base passes with ten fresh live/platform cases. The additional permission-restoration execution is excluded from the unique count. Compiled inventory identity matching covers every declared test; original failed ASan base and LAN executions remain retained separately and receive no pass credit.

The Local Network cases exercised actual permission ON, OFF and restored ON with a healthy backend, exact resource cleanup and restoration of the original permission entries. The TLS cases used fresh source-bound guest fixtures. Independent reviews retain the limits of captured child diagnostics; these test matrices do not establish complete child process at-exit diagnostic coverage, signed installed-artifact acceptance, provider lifecycle/soak completion, issue closure or GA readiness.

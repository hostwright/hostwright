# RC.12 supported source matrix

The frozen source is [`aa8586a1`](https://github.com/hostwright/hostwright/commit/aa8586a1ccc7887f7ae09dcccdc32bf13c27c705), version `0.0.2-rc.12`.
The [derived source matrix summary](source-matrix-summary.json) records **3,554 unique passing tests**: 3,493 XCTest and 61 Swift Testing cases, with no failures or skips in the completed aggregate.

The base actually passed 3,483 XCTest and 61 Swift Testing cases and skipped ten routed live cases. Ten fresh, unique live executions complete the aggregate; none of the skipped results is counted as a pass. The permission-restoration repeat is excluded from the unique count. The initial failed TLS execution remains retained, and only its successful retry is credited.

The original verifier output, independent review and raw execution records remain in the qualification packet. This summary publishes their hashes and individual live-case outcomes; it is not an export of those raw records. Source coverage does not establish sanitizer, signed-installation, RC, GA or official Homebrew acceptance.

The [runtime and fuzz summary](runtime-and-fuzz-summary.json) records the exact authenticated runtime archive and six fresh five-minute fuzz targets with retained corpus replay. Independent review verified their raw bindings and cleanup. Full sanitizer coverage, the hosted payload mismatch, and signed-artifact acceptance remain open.

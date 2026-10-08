# Supported source and sanitizer suite qualification

`scripts/release/verify-supported-suite-matrix.py` checks the complete compiled XCTest and Swift Testing identity union against retained base and attended executions. Run it before assembling the source-regression and sanitizer gate receipts. Its result is a local evidence check; protected acceptance still requires all release gates and their authenticated export.

## Inputs

Use an explicit config file outside the clean source checkout. Every path is absolute except a receipt or attachment path, which must stay within its declared evidence root.

| Config field | Required binding |
| --- | --- |
| `sourceRoot`, `sourceCommit`, `version` | Current clean checkout, exact commit and product version |
| `lane` | `source`, `address`, or `thread` |
| `compiledInventory`, `compiledInventorySHA256` | Actual `swift test list --skip-build` output and its digest |
| `binary`, `binarySHA256` | Unchanged test executable used for this lane |
| `routedSelectors` | Exact module/class/method identities of prerequisite-dependent cases |
| `base` | Evidence root, relative receipt, receipt digest and raw log |
| `baseSwiftXML` | Receipt-bound relative Swift Testing xUnit output |
| `attended` | Evidence root, relative receipt, receipt digest and raw log for each separately executed case |

The source base must be the complete `scripts/test.sh full` execution. Keep its original skipped results unchanged. Every routed case then needs one passing actual execution from the same source, version and test binary. The sanitizer base must execute every compiled native case except the precisely routed set, with no additional filter, and execute the complete Swift Testing inventory.

Every receipt must retain raw command output, execution mode, exit status and source cleanliness before and after. Attended runtime cases additionally bind cleanup proof attachments and passing unmanaged-resource preservation. Registry authentication and the deterministic scheduler fixture have no runtime-resource cleanup exemption beyond their exact existing selectors.

The base receipt must also carry `binarySHA256` and `compiledInventorySHA256`, matching the configured executable and retained inventory. Missing bindings and digests from another build are refused.

## Verification

Pass the config with `--config` and a fresh absolute result path with `--output`. The output must be outside the checkout. The verifier refuses missing, extra, duplicate, failed, skipped, mixed-source, mixed-version, mixed-binary, dirty, simulated, tampered or symlinked evidence. It also checks both framework summaries against the actual unique case identities.

A successful report records complete counts, the exact source and binary hashes, every retained receipt digest, and the executed routed identities. It explicitly records that original skipped results did not count as passing. Preserve the config, report and all referenced inputs together.

## Candidate boundaries

Older candidates remain historical. A correction that changes the qualification source requires a new candidate and complete source-bound acceptance. Four passing supplementary cases do not qualify a base missing six other required cases. A focused retry does not turn a failed full run into a passing result.

See the [testing evidence contract](testing-evidence.md) and [release process](../release/RELEASE_PROCESS.md).

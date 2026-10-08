# Historical RC.5 preparation and rejection

Source: `b23dd15d8fe4770a48012c70afc8449ed63676d6`. Version: `0.0.2-rc.5`.

These are summaries of retained preparation results, not a qualification acceptance record. The original raw receipts and failures remain in the private evidence retention. No RC.5 signed stage, protected acceptance, supported prerelease or GA publication was completed. A corrected source requires a new candidate and its own evidence.

| Record | Actual outcome |
| --- | --- |
| [Runtime producer](runtime-producer.json) | Exact authenticated producer completed; its archive passed independent local verification |
| [Source, fuzz and shards](source-fuzz-shards.json) | Six fuzz targets passed the duration and replay requirements; source coverage still lacked six actual attended cases; hosted live shard skipped all six cases |
| [Sanitizer disposition](sanitizer-disposition.json) | Two full ASan base runs failed; the second retained the scheduler reservation race failure with adequate storage; neither qualifies the sanitizer gate |
| [Historical object variance](historical-object-variance.json) | RC.2's sixteen differing module-hash bytes remain unexplained; its nine compared executables match; all-object reproducibility is not demonstrated |

## Failure follow-up

The original reservation race test discarded the unexpected losing error and required a capacity rejection immediately after one reservation call. Hostwright's state writer has a bounded lock wait. Other admission race fixtures retry only the typed writer-fence timeout, then still require one capacity winner and one insufficient-capacity refusal. The next candidate applies the same bounded qualification behavior, retains unexpected errors in assertion diagnostics, and exercises real writer contention plus refusal at an unrelated exclusive state fence. It does not change product lock limits or weaken capacity admission.

Focused correction tests and complete next-candidate source, sanitizer and signed-artifact qualification remain separate evidence. A passing focused retry cannot replace either failed full RC.5 run. Follow the [release process](../../release/RELEASE_PROCESS.md) and [supported-suite verification contract](../../reference/supported-suite-qualification.md).

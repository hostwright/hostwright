# GA readiness — RC.16 preparation, October 22, 2026

Current source prepares `0.0.2-rc.16`. No supported RC or GA has been published.
Manifest v3, Control API 2.2, state schema v24 and the single-Mac scope remain unchanged.

## Focused producer repair

RC.15’s [runtime producer](https://github.com/hostwright/hostwright/actions/runs/39828119259)
built the expected kernel, then failed source capture because its explicit patch
ledger listed four of the seven patches applied by the kernel profile. This
repair includes the remaining three patches in order and adds a regression
check against the complete declared series. It changes no kernel patch,
configuration or payload pin. The verified kernel SHA-256 remains
`1ea99b8be7e6becdb255bd8dffcd0434f6725cab2514f3386b667d3d8ad4ad91`.
The [two matching kernel builds](https://github.com/hostwright/hostwright/actions/runs/39814342881)
retain their original source bindings and remain evidence for those bytes.

The additional focused repair round was explicitly authorized on October 22.
The website Vite security correction has been merged separately. The
[RC.15 record](ga-readiness-2026-10-22-rc15.md) remains historical. Its interrupted
physical source run and completed hosted jobs retain their actual source and
version bindings; they do not qualify RC.16. No signed RC.15 stage was produced.

## Closing sequence and stop conditions

1. Review this complete repair, freeze RC.16 and run each mandatory qualification
   once. Reuse valid unchanged-input evidence without relabeling candidate-bound
   results. A blocking failure after this freeze ends the attempt.
2. Close #271, #277, #278 and #279 only after their provider cycles/soak,
   workload recovery, signed lifecycle and live quickstart/accessibility gates
   pass. Share qualifying runs and receipts across issues.
3. After RC acceptance, review the final `0.0.2` version change, qualify its exact
   signed bytes once, publish and verify downloads/vendor-tap installation (#281).
4. Audit and submit the cask against the public stable bytes. Keep #282, #283
   and #284 open until official Homebrew acceptance and fresh-machine
   `brew install hostwright` pass. Awaiting external review triggers no retesting.

No new repair round starts after 8 p.m. Eastern. Stop at 11:59 p.m. Eastern
with completed GA or a precise unfinished-gate report. Missing authorization,
credentials or lab capacity, signing failure and Homebrew review remain blockers.
See the [acceptance contract](../reference/release-promotion.md).

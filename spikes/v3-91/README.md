# V3-91 link transport spike

This standalone SwiftPM executable compares three D7 link transports over IPv4 loopback on macOS 26. An isolated disposable keychain supplies separate, non-exportable worker and control identities. Both peers require and verify the exact test certificate of the other peer. The link carries test bytes and uses ephemeral ports.

## Run

From the repository root, build once and run the release binary:

```sh
sw_vers
sysctl -n hw.model hw.logicalcpu
swift build -c release --package-path spikes/v3-91
bin="$(swift build -c release --package-path spikes/v3-91 --show-bin-path)/v391-link-transport"
"$bin" quic 0 on
"$bin" quic 1 off
"$bin" http2 4 none
"$bin" mux 4 on
"$bin" quic-modern
"$bin" security
```

Each transport accepts `0`, `1` or `4` bulk streams. Use `on` or `off` with QUIC and the custom mux. QUIC changes the send context from equal priority 0.5 to RPC priority 1 and bulk priority 0. The mux switches from FIFO to serving queued control frames before bulk. HTTP/2 uses `none` because this spike has no dedicated RPC scheduler. Calling a transport without load arguments runs its original single-stream case and includes the QUIC idle-survival probe.

Run candidates sequentially on an idle Mac. For the D7 outcome, keep each candidate's priority setting fixed across load levels. Use three repeats per load and report the median and range of each run's p50 and p99. The recorded matrix also included an exploratory on/off comparison. Every invocation creates new fixture identities. Both accepted peer-verification counts must be positive. Use `V391_TRACE=1` to see the QUIC stream setup and single-stream cancellation steps.

The bulk senders continuously queue 16 KiB chunks. After each receiver observes a chunk and the control peer completes 20 untimed echoes, the peer times 500 sequential 32-byte echoes on a separate stream with 2 ms between echoes. A sample ends when the control peer validates the echoed bytes. p50 and p99 use nearest rank. Throughput counts bulk payload delivered during sampling in MiB/s. Each loaded run requires every bulk stream to advance in at least half the intervals. Zero-bulk runs report zero bulk progress and give an unloaded baseline.

**D7 outcome.** Require all 500 control echoes to complete and every active bulk stream to keep progressing in each run. Compare loaded p50 and p99 with the same candidate's idle baseline, then compare one and four bulk streams. Record whether control latency stays near the idle range, grows with bulk concurrency, or is obscured by run-to-run variation. A loopback result characterizes RPC response under this load. D7's heartbeat and starvation behavior on a constrained or lossy link remains for the later network tests.

| Transport configuration | Idle p50 / p99 (ms) | One bulk stream | Four bulk streams |
| --- | ---: | ---: | ---: |
| QUIC, priority hint on | 0.143 / 0.422 | 0.100 / 0.199 | 0.206 / 0.346 |
| HTTP/2 | 0.194 / 0.575 | 0.185 / 0.293 | 0.261 / 0.421 |
| TLS mux, priority queue on | 0.192 / 0.458 | 0.902 / 1.086 | 3.500 / 4.066 |

Values are medians of three release-mode runs per combination. All control echoes completed and every loaded stream progressed in every sample interval. QUIC had the smallest median RTT at four streams. Both QUIC and HTTP/2 increased median p50 by less than 0.07 ms from idle to four streams, and their four-stream median p99 values were below their idle medians. HTTP/2's four-stream p99 ranged from 0.417 to 1.054 ms and its independent worker-initiated RPC requirement remains unmet. The TLS mux showed a clear load-dependent latency penalty: p50 rose about 4.7× at one stream and 18.2× at four. Its 16 × 16 KiB credit window holds 256 KiB per bulk stream. At about 288 MiB/s aggregate, draining a full window takes about 0.87 ms for one stream and 3.47 ms for four. The measured p50 values are consistent with control bytes waiting behind bulk already admitted below the mux scheduler. The queue location remains unmeasured.

**Priority mechanism.** A peer-visible effect of either on/off switch was not measurable on loopback in this experiment. Reserve any further mechanism comparison for a constrained path. QUIC's zero-bulk p99 medians differed by 0.073 ms, larger than its loaded on/off median differences. Its hint is set on the separate stream connections. Apple describes ordering for queued send contexts and does not specify scheduling across QUIC streams. The mux counter measures choices before TCP accepts bytes. HTTP/2 has no dedicated priority switch in this experiment. [Apple send-context priority](https://developer.apple.com/documentation/network/nwconnection/contentcontext/relativepriority)

`quic-modern` separately tests `NetworkListener<QUIC>` and `NetworkConnection<QUIC>` with the same pinned credentials and captures connection states or the exact eight-second watchdog expiry. The benchmark's `quic` command uses the existing `NWConnectionGroup` path.

`security` checks two independent authenticated sessions per transport. Within each session the 32-byte TLS exporter matches across peers. Between sessions the values must differ. It uses the V3-14 label and prints only lengths and verification outcomes. The same isolated identities also supply a matched ALPN-mismatch control, an absent-certificate case, and a different-certificate case. Certificate refusals require zero application bytes and no echo, and QUIC also requires no worker readiness or stream delivery. A QUIC dialer can briefly report ready before refusal. In the observed run, QUIC surfaced POSIX 22 for the certificate and ALPN cases. The certificate evidence comes from the matched setup, the peer pin callbacks, and the worker state history.

## What the cases probe

- **QUIC.** `NWListener.newConnectionGroupHandler`, `NWMultiplexGroup`, and `NWConnectionGroup` keep streams on the control-initiated connection. The worker opens a bidirectional stream, the control opens independent RPC and bulk streams, and the worker sees a cancellation code without losing the group. QUIC limits the transport stream window and advertised stream count. Fixed-size application reads bound accepted RPCs and each bulk read. The peers configure keepalive and check an echo after an idle period. The send context requests higher priority for RPC bytes, while scheduling priority across independent QUIC streams remains unverified. [Network.framework](https://developer.apple.com/documentation/network), [QUIC transport specification](https://www.rfc-editor.org/rfc/rfc9000.html)
- **HTTP/2.** SwiftNIO Transport Services supplies Network.framework TLS to NIOHTTP2. The benchmark uses distinct client-initiated RPC and bulk streams, checks peer limits and flow-control frames, and exercises HTTP/2 PING and stream reset. Server push belongs to a client request and cannot open an independent worker RPC. The sample uses no separate priority scheduling. The production adoption estimate is three direct SwiftPM package declarations for SwiftNIO, NIOHTTP2 and SwiftNIO Transport Services. Each package already has a license inventory entry, so the estimate is zero new entries. [SwiftNIO Transport Services](https://github.com/apple/swift-nio-transport-services), [HTTP/2 specification](https://www.rfc-editor.org/rfc/rfc9113.html)
- **Custom mux.** Network.framework TLS 1.3 follows the existing service tunnel's identity and peer-authentication pattern. Both sides open streams. The mux has an eight-stream limit, a 16 KiB payload cap, a 16-frame bulk credit window, an explicit cancellation frame, and a heartbeat exchange. The writer serves queued RPC and control frames ahead of bulk and reports how many times both queues were nonempty when it chose the priority lane. This measures the application's scheduling before TCP accepts the bytes. One TLS/TCP connection still has TCP's head-of-line behavior.

Apple frameworks add no package or license inventory entry for QUIC or the custom mux. Use physical Swift source lines per candidate as a rough review and fuzzing estimate and report the shared harness and keychain fixture separately. The issue records the measured comparisons. C7 makes the transport decision after the V3-14 VM evidence.

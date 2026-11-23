# V3-91 link transport spike

This standalone SwiftPM executable compares three D7 link transports over IPv4 loopback on macOS 26. An isolated disposable keychain supplies separate, non-exportable worker and control identities. Both peers require and verify the exact test certificate of the other peer. The link carries test bytes and uses ephemeral ports.

## Run

From the repository root:

```sh
sw_vers
sysctl -n hw.model hw.logicalcpu
swift build --package-path spikes/v3-91
swift run --package-path spikes/v3-91 v391-link-transport quic
swift run --package-path spikes/v3-91 v391-link-transport http2
swift run --package-path spikes/v3-91 v391-link-transport mux
wc -l spikes/v3-91/Sources/V391/*.swift
```

Run candidates sequentially on an idle Mac. Every invocation creates new fixture identities. The command prints both accepted peer-verification counts and the transport-specific observations before exiting. Use `V391_TRACE=1` to see the QUIC stream setup and single-stream cancellation steps.

The bulk sender queues 16 KiB chunks continuously. Once the bulk receiver observes the first chunk, the control peer times 500 sequential 32-byte application echoes on a separate stream, pausing 2 ms between echoes. Latency is round-trip time. p50 and p99 use nearest rank. Throughput counts only bulk payload delivered to the receiver during the sampling interval in MiB/s. The output also counts intervals with bulk progress and rejects a run in which fewer than half show progress. Protocol handshakes, stream setup, and capability probes occur before the sample. These measurements describe the local debug build over loopback.

## What the cases probe

- **QUIC.** `NWListener.newConnectionGroupHandler`, `NWMultiplexGroup`, and `NWConnectionGroup` keep streams on the control-initiated connection. The worker opens a bidirectional stream, the control opens independent RPC and bulk streams, and the worker sees a cancellation code without losing the group. QUIC limits the transport stream window and advertised stream count. Fixed-size application reads bound accepted RPCs and each bulk read. The peers configure keepalive and check an echo after an idle period. The send context requests higher priority for RPC bytes, while scheduling priority across independent QUIC streams remains unverified. [Network.framework](https://developer.apple.com/documentation/network), [QUIC transport specification](https://www.rfc-editor.org/rfc/rfc9000.html)
- **HTTP/2.** SwiftNIO Transport Services supplies Network.framework TLS to NIOHTTP2. The benchmark uses distinct client-initiated RPC and bulk streams, checks peer limits and flow-control frames, and exercises HTTP/2 PING and stream reset. Server push belongs to a client request and cannot open an independent worker RPC. The sample uses no separate priority scheduling. The production adoption estimate is three direct SwiftPM package declarations for SwiftNIO, NIOHTTP2 and SwiftNIO Transport Services. Each package already has a license inventory entry, so the estimate is zero new entries. [SwiftNIO Transport Services](https://github.com/apple/swift-nio-transport-services), [HTTP/2 specification](https://www.rfc-editor.org/rfc/rfc9113.html)
- **Custom mux.** Network.framework TLS 1.3 follows the existing service tunnel's identity and peer-authentication pattern. Both sides open streams. The mux has an eight-stream limit, a 16 KiB payload cap, a 16-frame bulk credit window, an explicit cancellation frame, and a heartbeat exchange. The writer serves queued RPC and control frames ahead of bulk and reports how many times both queues were nonempty when it chose the priority lane. This measures the application's scheduling before TCP accepts the bytes. One TLS/TCP connection still has TCP's head-of-line behavior.

Apple frameworks add no package or license inventory entry for QUIC or the custom mux. Use physical Swift source lines per candidate as a rough review and fuzzing estimate and report the shared harness and keychain fixture separately. The issue records the provisional pick. The transport decision waits for the V3-14 VM evidence.

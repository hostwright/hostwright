# Docker Engine compatibility slice

This document describes the Phase 13 Docker Engine surface implemented by
`HostwrightDockerEngine`. It is an implementation contract, not a release
claim or a Docker client conformance report. The executable contract is
[`phase13-docker-engine-v1.json`](../../contracts/v0.0.2/phase13-docker-engine-v1.json).

The proxy is a local, read-only HTTP/1.1 endpoint. It sends container, image,
info, and one-shot event reads through the Phase 09 `PersistentControlClient`
and `CLIControlRoute`; it does not read runtime or state directly. Ping and
version are local responses and do not contact the Control API.

## Negotiation and endpoints

The supported Docker API versions are exactly `1.52`, `1.53`, `1.54`, and
`1.55`. A version can be supplied as `/v1.52/...` or in the
`Docker-API-Version` header. If both are present they must match. An absent
version negotiates the highest supported version. Versions outside the range,
malformed versions, and mismatches return a stable JSON `400` response before
any Control API request.

The advertised read matrix is:

| Method | Path | Authority | Control operation |
| --- | --- | --- | --- |
| `HEAD`, `GET` | `/{version}/_ping` | proxy-local | — |
| `GET` | `/{version}/version` | proxy-local | — |
| `GET` | `/{version}/info` | Phase 09 Control API | `status` |
| `GET` | `/{version}/containers/json` | Phase 09 Control API | `status` |
| `GET` | `/{version}/containers/{id}/json` | Phase 09 Control API | `inspect` |
| `GET` | `/{version}/images/json` | Phase 09 Control API | `status` |
| `GET` | `/{version}/images/{reference}/json` | Phase 09 Control API | `image` |
| `GET` | `/{version}/events` | Phase 09 Control API | `events` (one-shot read) |

The same endpoint paths may be used without a version prefix; negotiation
still occurs and the response advertises the chosen API version. Each
advertised endpoint is covered for all four supported versions. Mutating
container/image operations, networks, volumes, build/pull, exec/attach/log
streams, event streams, and protocol upgrades are not advertised. They fail
explicitly before a control request.

## HTTP boundary

The parser accepts origin-form HTTP/1.1 requests with bounded
`Content-Length` or a bounded `chunked` body. It rejects malformed framing,
duplicate framing headers, unsupported transfer encodings, request smuggling
trailing bytes, upgrades, and oversized input. Responses use stable sorted
headers, an exact `Content-Length`, and JSON `{ "message": "..." }` errors.
The foreground daemon handles one request per Unix-socket connection and then
closes it; `HEAD` preserves the response length while suppressing the body.

Control failures are reduced to stable unavailable/rejected messages. Raw
control errors, paths, tokens, and other details are not returned to the
Docker client.

The Docker client matrix and live Docker Desktop evidence remain separate
gates. This slice does not start Docker Desktop, create containers, or claim
full Docker, Compose, Podman, or Testcontainers compatibility.

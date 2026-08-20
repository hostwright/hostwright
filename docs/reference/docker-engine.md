# Docker Engine compatibility slice

This document describes the Phase 13 Docker Engine surface implemented by
`HostwrightDockerEngine`. It is an implementation contract, not a release
claim or a Docker client conformance report. The executable contract is
[`phase13-docker-engine-v1.json`](../../contracts/v0.0.2/phase13-docker-engine-v1.json).

The proxy is a local, read-only HTTP/1.1 endpoint. Ping and version are local
responses. Container, image, info, and event request shapes are recognized for
version negotiation, but they are deliberately unsupported: the proxy returns
a stable JSON `404` before any Control API operation, runtime access, state
access, or manifest read. No non-local Docker-authoritative producer exists in
this contract.

## Negotiation and endpoints

The supported Docker API versions are exactly `1.52`, `1.53`, `1.54`, and
`1.55`. A version can be supplied as `/v1.52/...` or in the
`Docker-API-Version` header. If both are present they must match. An absent
version negotiates the highest supported version. Versions outside the range,
malformed versions, and mismatches return a stable JSON `400` response before
any Control API request.

The advertised read matrix is:

| Method | Path | Behavior | Status |
| --- | --- | --- | --- |
| `HEAD`, `GET` | `/{version}/_ping` | proxy-local response | `200` |
| `GET` | `/{version}/version` | proxy-local response | `200` |
| `GET` | `/{version}/info` | unsupported before Control API | `404` |
| `GET` | `/{version}/containers/json` | unsupported before Control API | `404` |
| `GET` | `/{version}/containers/{id}/json` | unsupported before Control API | `404` |
| `GET` | `/{version}/images/json` | unsupported before Control API | `404` |
| `GET` | `/{version}/images/{reference}/json` | unsupported before Control API | `404` |
| `GET` | `/{version}/events` | unsupported before Control API | `404` |

The same endpoint paths may be used without a version prefix; negotiation
still occurs and the response advertises the chosen API version. Each
advertised endpoint is covered for all four supported versions. Advertising a
non-local path means the proxy recognizes and rejects that versioned request;
it is not a successful-read or Control API support claim. Mutating
container/image operations, networks, volumes, build/pull, exec/attach/log
streams, event streams, and protocol upgrades are not advertised. They also
fail explicitly before a control request.

## HTTP boundary

The parser accepts origin-form HTTP/1.1 requests with bounded
`Content-Length` or a bounded `chunked` body. It rejects malformed framing,
duplicate framing headers, unsupported transfer encodings, request smuggling
trailing bytes, upgrades, and oversized input. Responses use stable sorted
headers, an exact `Content-Length`, and JSON `{ "message": "..." }` errors.
The foreground daemon handles one request per Unix-socket connection and then
closes it; `HEAD` preserves the response length while suppressing the body.

Non-empty query intent is rejected before endpoint dispatch and query values
are never reflected. Malformed query syntax returns a stable JSON `400`;
well-formed but unsupported query intent returns the same redacted `404` as
other unsupported operations. Cancellation is checked first and returns
`499`, including for a recognized non-local read. Non-local reads never make a
Control API request, so this contract publishes no Control-unavailable
response. Paths, tokens, manifest contents, and other details are not returned
to the Docker client.

The Docker client matrix and live Docker Desktop evidence remain separate
gates. This slice does not start Docker Desktop, create containers, or claim
full Docker, Compose, Podman, or Testcontainers compatibility.

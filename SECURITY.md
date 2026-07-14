# Security Policy

Prism is a live-video production app that can ingest networked cameras, run a
local control server, and publish a system-wide virtual camera. Security of
those surfaces is taken seriously.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** — open a
[GitHub security advisory](https://docs.github.com/en/code-security/security-advisories/guiding-contributors-to-report-security-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository rather than a public issue. Include reproduction steps and
the affected version/commit. Please allow time for a fix before public
disclosure.

## Design posture

Network- and IPC-facing surfaces are built to fail closed:

- **Networked cameras (PrismLink):** pairing uses a **mutual** challenge–response.
  Both sides prove knowledge of the short pairing code, each proof bound (HMAC)
  to the server's TLS certificate and a per-connection nonce. A phone withholds
  all camera media until the Mac proves it knows the code, so a spoofed
  first-contact server on the LAN cannot harvest video. The server's certificate
  is pinned on first successful pair (TOFU).
- **Control server (obs-websocket):** binds **loopback-only by default**. A
  network-reachable bind is refused unless a password is configured, so the
  record/stream control surface is never exposed to the LAN unauthenticated.
- **Virtual camera:** the sink that feeds the camera only accepts a client whose
  code-signing identity carries Prism's bundle prefix, so an arbitrary local
  process cannot inject frames into the camera other apps consume.

## Scope notes

This is an unreleased work-in-progress. Some hardening is bounded by platform
APIs (for example, CMIO exposes only a client signing identifier, not a full
`SecCode`, so the virtual-camera gate is a bundle-prefix check rather than a
team-ID/cdhash designated requirement). Such limits are documented at the
relevant call sites in the source.

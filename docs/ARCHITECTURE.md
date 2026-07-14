# Prism — Architecture

This is the engineering map: how the modules fit, the one contract everything obeys, and how correctness is enforced. For the product design (vision, feature tiers, the hard-parts analysis) see [../DESIGN.md](../DESIGN.md).

## The one load-bearing idea: a single frame contract

Every subsystem plugs into one contract defined in **PrismCore**, and that contract is what makes the rest composable:

- **`VideoFrame`** — an IOSurface-backed `CVPixelBuffer` + a presentation timestamp in *house time* + a `SourceID`. Its initializer asserts the buffer is IOSurface-backed, so a CPU-copied buffer can never enter the graph (the zero-copy invariant is enforced at the boundary, not by convention).
- **`HouseClock`** — the single timing authority (`CMClockGetHostTimeClock`). Mac captures already stamp host-clock PTS; network devices translate into house time before sending. Everything downstream compares one clock.
- **`FrameMailbox`** — a latest-wins, depth-bounded handoff between a source's capture thread and the compositor's render thread. Live compositing never queues deep; ISO recording taps ahead of the mailbox with a real FIFO so recordings don't drop when the live mix does.
- **`PixelBufferPool`** — the only sanctioned way to mint buffers, so IOSurface/Metal compatibility is automatic.

Because a camera, a screen grab, a decoded network frame, and a rendered text overlay all become the *same* `VideoFrame`, the compositor, encoders, recorders, virtual camera, and streaming outputs never know or care what a source is.

## Module graph

The engine is 19 modules. `PrismCore` is the root; nothing depends the other way.

```
                         ┌────────────┐
                         │ PrismCore  │  frame contract, house clock, mailbox, pools, logging
                         └─────┬──────┘
        ┌───────────────┬──────┼───────────────┬────────────────┐
    INGEST            COMPOSITE   EFFECTS      AUDIO           OUTPUT / TRANSPORT
  PrismCapture      PrismCompositor  PrismColor   PrismAudio    PrismOutput
  PrismScreen       PrismAnimation   PrismVision                PrismLink / PrismLinkSender
  PrismSources      PrismCompose     (color/LUT/                PrismVirtualCam
  PrismLink(recv)                     chroma+luma/               PrismControl (obs-websocket)
                                      segmentation/HDR)          PrismControlSurface (MIDI)
                                                                 PrismProximity (BLE)
                                                                 PrismExport (FCPXML)
                                                                 PrismDirector (auto-switch)
```

| Module | Responsibility |
|---|---|
| **PrismCore** | The frame contract above + `EngineLog` signposts. |
| **PrismCapture** | AVFoundation cameras/mics with hot-plug; UVC capture cards and Continuity Camera appear as cameras. |
| **PrismScreen** | ScreenCaptureKit displays/windows/apps + per-app and system audio. |
| **PrismSources** | Generated sources: text/title, image, browser (offscreen WKWebView). |
| **PrismLink** / **PrismLinkSender** | The iOS-device transport. Mac receiver (`PrismLink`) and device sender (`PrismLinkSender`): QUIC over Bonjour, code-derived TLS pairing with cert pinning, HEVC over unreliable datagrams (reliable-stream fallback), per-peer clock sync. |
| **PrismCompositor** | The zero-copy Metal compositor + the `mach_wait_until` render loop + scene transitions. Runtime-compiled MSL; one fused pass. SDR and opt-in 10-bit HDR (HLG/Rec.2020). |
| **PrismAnimation** | Pure keyframe engine (tracks, easing, springs) — evaluates to a plain `Scene`, so the compositor stays dumb. Drives layer motion and transitions. |
| **PrismCompose** | Dual composition: a second program at a different aspect (16:9 + 9:16 from one show). |
| **PrismColor** | Metal color pipeline: grade wheels, 3D LUTs, auto-color, shot-match, relight, chroma + luma key with matte view. |
| **PrismVision** | Person segmentation (Vision/ANE) off the render path → matte for background remove/blur/replace. |
| **PrismAudio** | AVAudioEngine mixer, per-channel meters, LUFS metering, ducking, AUv3 inserts, voice isolation. |
| **PrismOutput** | VideoToolbox encode, crash-safe recording, per-source ISO, replay buffer, RTMP + SRT + multi-destination broadcasting. |
| **PrismVirtualCam** | CoreMediaIO camera extension (separate sandboxed process) + host-side feeder + system-extension installer. |
| **PrismControl** | obs-websocket v5 server (an engine-agnostic `ControlBackend` seam the app implements). |
| **PrismControlSurface** | CoreMIDI client + MIDI-learn → abstract surface actions. |
| **PrismProximity** | CoreBluetooth presence discovery (the pairing code never crosses BLE; media stays on Wi-Fi). |
| **PrismExport** | FCPXML 1.11 multicam project generation from a recorded session. |
| **PrismDirector** | Vision-driven auto-switch (hysteresis / min-shot / cooldown) + auto-framing. |

## The video pipeline, end to end

```
capture → house-timestamp → per-source effect chain → mailbox → Metal compositor → program VideoFrame
  (each source's chain: color grade → key (chroma/luma) → segmentation background; skipped when identity)
                                                                     │
        program frame fans out (once each, in parallel on the media engines):
        ├─ VideoToolbox encode → RTMP / SRT / multi-destination broadcaster
        ├─ VideoToolbox encode → AVAssetWriter (crash-safe recording) + replay ring
        ├─ IOSurface queue → CoreMediaIO extension (the system virtual camera)
        ├─ second composite (PrismCompose) → vertical 9:16 program → its own encode/record
        └─ CAMetalLayer preview(s)
  ISO taps sit BEFORE the mailboxes (real FIFO) so per-source recordings never drop.
  Audio runs a parallel AVAudioEngine graph → master mix → recorder + stream + monitor.
```

Two rules make this safe and fast:

1. **Zero-copy or die.** Every buffer is IOSurface-backed from capture to encoder; `CVMetalTextureCache` wraps them as Metal textures (a pointer exchange on unified memory). Any CPU pixel read on the hot path is a bug; debug assertions catch non-IOSurface buffers at the boundary.
2. **The render thread pulls.** A dedicated `mach_wait_until` thread ticks at output fps; each tick it takes each source's newest frame older than `deadline − compensation` from its mailbox, composites in one fused pass, and hands the program frame to the fan-out. Sources that stop posting hold their last frame rather than going black.

## The app layer

`App/PrismApp/` is a SwiftUI shell over the engine. **`AppEngine`** (`@MainActor`) owns the compositor, render loop, per-source mailboxes and effect pipelines, the audio mixer, and the output/transport objects; it implements the `ControlBackend` seam so obs-websocket, App Intents, and the MIDI surface all drive the same intents. Engine callbacks hop to the main actor for `@Published` state. The virtual camera is a system-extension target embedded in the app bundle; the iOS companion (`PrismCamera`) is a separate app target that uses `PrismLinkSender`.

## Verification model

The correctness envelope is **enforced by CI, not by a manual ritual** — a lesson learned the hard way (see the findings ledgers). Every module exposes a public `SelfTest.run()` that exercises its real logic on synthetic, TCC-free inputs (headless Metal, AVAudioEngine manual rendering, VideoToolbox encode, XML/DTD validation). These are wired two ways:

- **`swift test`** — `Tests/PrismSuiteTests` wraps each suite as an XCTest, so `swift test` (and CI) fails on any regression. This matters because the hot paths use `@unchecked Sendable` + hand-rolled locks the compiler can't check.
- **`prism-dev selftest`** — the same suites via the CLI, human-readable, plus `bench` (judged 4K60 stress), `pipeline`, `capture`, and QUIC `link` loopback.

On top of the self-tests, **every subsystem was reviewed through independent adversarial cross-verification**, which repeatedly caught end-to-end failures that green isolated tests could not — e.g. a decoder emitting a pixel format the compositor couldn't sample, an SRT output that transmitted nothing on a real server because of a mux gate, and an auto-director that cut to unplugged cameras. The rule that came out of it, and that this codebase now follows: **an isolated self-test verifies what you thought to test; it is not end-to-end verification, and nothing ships on the builder's own say-so.** Fixes are cross-verified too.

Anything needing real hardware or a live network endpoint (keying quality on real footage, loudness on real audio, RTMP/SRT bytes-on-wire, the virtual camera in an actual call) is explicitly marked UNVERIFIED-by-runtime — sound by construction and synthetic tests, awaiting a signed build on real signal.

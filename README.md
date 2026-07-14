# Prism

A native, Apple-ecosystem **live video production** application for macOS — "OBS Studio, built the way Apple would build it." Prism ingests multiple simultaneous live sources, composites them into scenes with real-time GPU effects, and fans out to recording, live streaming, and a system-wide virtual camera — with a zero-copy Metal pipeline, ANE-accelerated effects, and multiple iPhones/iPads usable as independent networked cameras at once.

> Status: engine + app feature-complete against the design (MVP + v1 + v2 + stretch). 19 engine modules, 22 module self-test suites run under `swift test`, 4K60 compositor benchmark, zero build warnings. Every subsystem has been adversarially cross-verified via independent review. See [DESIGN.md](DESIGN.md) for the full product design and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the engineering map.

## What it does

| Area | Capabilities |
|---|---|
| **Ingest** | Mac cameras/mics/UVC capture cards · display/window/app capture + per-app & system audio (ScreenCaptureKit + CATap) · Continuity Camera · **multiple iPhones/iPads as independent live cameras over the LAN** (paired QUIC transport) · text / image / browser sources |
| **Compositing** | Zero-copy Metal compositor · layers with transform/crop/opacity · PiP presets · crossfade/slide transitions · scene collections · multiview · keyframed motion · simultaneous 16:9 + 9:16 dual program |
| **Effects** | Color grading + 3D LUTs · person-segmentation background removal (Vision/ANE) · chroma **and** luma key with matte view · HDR (P3/HLG/Rec.2020, 10-bit) |
| **Audio** | N-channel mixer (gain/mute/solo, live meters) · LUFS loudness (BS.1770) · sidechain ducking · AUv3 effect inserts · voice isolation · multitrack per-source recording |
| **Output** | Crash-safe recording (H.264/HEVC/ProRes) · per-source ISO recording · replay buffer · FCPXML multicam export · RTMP + SRT + **multi-destination** streaming · CoreMediaIO **virtual camera** |
| **Control** | obs-websocket v5 (compatible with existing tooling) · App Intents / Shortcuts · CoreMIDI + MIDI-learn · BLE proximity discovery · preflight "Broadcast Check" · Vision Auto-Director (auto-switch + auto-frame) |

## Repository layout

```
Prism/
├── DESIGN.md              product design: vision, full feature set, architecture, hard parts
├── docs/ARCHITECTURE.md   engineering map: module graph, the frame contract, verification model
├── PrismStudio/           the engine — a Swift Package (19 PrismX modules, no AppKit)
│   ├── Sources/PrismCore/ …the frame contract: house clock, VideoFrame, FrameMailbox, PixelBufferPool
│   ├── Sources/prism-dev/ …developer CLI: selftest / pipeline / bench / capture / link / control
│   └── Tests/              XCTest gate wrapping every module self-test
└── App/                   the Mac/iOS app family (SwiftUI shell + CMIO extension + iOS companion)
    ├── project.yml         XcodeGen spec (Prism macOS app · PrismVCamExtension · PrismCamera iOS)
    └── PrismApp/           the app: AppEngine + views
```

The **engine** (`PrismStudio/`) is a platform-agnostic Swift Package with no AppKit/SwiftUI — all UI lives in the **app** (`App/`), which is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Building & running

Prerequisites: Apple Silicon Mac, macOS 14.2+, Xcode 26+, `xcodegen` (`brew install xcodegen`).

> This machine's `xcrun` default SDK is misconfigured, so engine builds pin the SDK explicitly. If yours is fine, drop the `SDKROOT=…` prefix.

### Engine — build, self-test, benchmark

```sh
cd PrismStudio
SDKROOT=$(xcrun --show-sdk-path) swift build
swift test                          # 22 module suites + core tests, all green
swift run prism-dev selftest        # same suites via the CLI, human-readable
swift run prism-dev bench 20 5      # 20 judged runs of 8×4K sources → 4K60 program + HEVC
swift run prism-dev pipeline 4      # synthetic 2-source → compositor → recording
swift run prism-dev devices         # enumerate cameras/mics (no capture started)
swift run prism-dev capture         # LIVE camera → compositor → recording (Camera TCC prompt)
```

### App — generate the Xcode project and build

```sh
cd App
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen
# Debug builds ad-hoc (no signing identity required):
xcodebuild -project Prism.xcodeproj -scheme Prism -configuration Debug \
  CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES build
```

Three targets: **Prism** (macOS app), **PrismVCamExtension** (the CoreMediaIO virtual-camera system extension, embedded in the app bundle), and **PrismCamera** (the iOS companion that turns an iPhone/iPad into a networked camera).

## Requires an Apple Developer account (not covered by ad-hoc Debug)

Two capabilities need a signed build (paid Apple Developer Program for the system extension; a connected device for iOS install):

- **Virtual camera in Zoom/Meet/FaceTime** — activating the CoreMediaIO system extension requires the restricted `system-extension.install` entitlement.
- **Installing Prism Camera on an iPhone/iPad** — requires the device connected over USB to mint a provisioning profile.

Everything else — recording, streaming, compositing, all effects and audio — runs from an ad-hoc Debug build.

## Verification

Correctness is enforced, not asserted. `swift test` runs every module's self-test as an XCTest (headless GPU/DSP checks on synthetic inputs, no camera/mic needed). The design's hardest guarantees — zero-copy invariants, the house-clock timing model, 4K60 sustained throughput, the streaming/transport gates — each have a dedicated executable check. Every subsystem was additionally hardened through independent adversarial review of each module.

### Verified on real hardware / real wire

Beyond the synthetic self-tests, these paths have been exercised on real signal (a Logitech StreamCam, a local media server, and the iOS Simulator):

- **Live camera capture → compositor → HEVC recording** — real USB webcam, real footage recorded and confirmed decodable.
- **Webcam → RTMP round-trip** — the real camera streamed through the full pipeline (capture → compositor → H.264+AAC encode → RTMP) to a local server, with a frame pulled back off the wire.
- **RTMP, SRT, and multi-destination streaming** — all publish a live 2-track (H.264 + AAC) stream to a real server, server-confirmed; one dead destination doesn't stall the others.
- **iOS companion transport** — the real PrismCamera app in the iOS Simulator paired (cert-bound challenge) and streamed HEVC over QUIC to the Mac across two real OS processes.
- **Overlay compositing** — a text/logo overlay composites correctly over live camera video (transparent areas show the video through).

Still genuinely UNVERIFIED-by-runtime, awaiting a signed build or specific hardware: the virtual camera inside a real video-call app (needs a signed system extension), loudness/keying quality on real footage against a reference, and RTMP/SRT to a live public platform (YouTube/Twitch). These are marked in the code and self-tests.

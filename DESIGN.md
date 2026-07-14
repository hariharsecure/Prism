# PRISM — Apple-Native Live Video Production
**Design document v0.1 — 2026-07-07**
Product architect/tech lead: Fable. Codename "Prism" is a placeholder.

---

## 0. KEY ASSUMPTIONS (read first — these shape everything)

| # | Assumption | Why | Fork if wrong |
|---|-----------|-----|---------------|
| A1 | **Apple Silicon only, macOS 14.2+** | Unified memory makes zero-copy trivial; media engines give free parallel encodes; CATap (system-audio capture) needs 14.2; supporting Intel doubles perf work for a dying base | If Intel needed: drop 4K60 target, add discrete-GPU copy paths |
| A2 | **Primary use = solo creator, live-streaming and virtual-cam-for-calls are co-equal; recording is the "pro tail"** | Streaming is the OBS use case; virtual cam is the *daily* wedge (every Zoom call); ISO recording is the differentiator for pros | If recording-first: promote ProRes/ISO/FCPXML from v1 to MVP, demote RTMP |
| A3 | **Program target = 1080p60 rock-solid; 4K30 v1; 4K60 stretch** | 1080p60 is what platforms ingest; 4K60 program is a perf project, not a feature | If 4K60-first: budget an extra perf phase, P010 pipeline earlier |
| A4 | **Up to 4 simultaneous iOS devices** as independent feeds | Covers real multi-angle setups (front/side/top/handheld); LAN bandwidth math works (4 × 12 Mbps HEVC ≈ 48 Mbps, fine on Wi-Fi 6) | 8+ devices → wired-Ethernet-first design, mDNS relay, dedicated AP guidance |
| A5 | **Solo operator** | UI is one-person: preview/program + hotkeys, not a multi-seat switcher | Multi-operator → the iPad remote becomes a peer control surface with roles/locks (stretch already sketches this) |
| A6 | **macOS is the hub; iOS companion is a capture/remote app, not a full iPad production app** | The Mac has the media engines, the extension APIs, the I/O | Full iPad app → separate product decision; the engine layers below are portable by design (no AppKit in the engine) |
| A7 | iOS 17+ for the companion (Vision instance masks, modern VideoToolbox low-latency RC, Network.framework QUIC maturity) | | |

---

## 1. VISION

Prism is a Mac-native live production studio that treats your Apple devices as one camera system: every iPhone and iPad on your network becomes an independent, hardware-encoded, clock-synced camera angle; your Mac's screens, windows, apps, cameras and audio are first-class sources; and one zero-copy Metal pipeline composites them into scenes and fans out simultaneously to recording, streaming, and a system-wide virtual camera. It beats OBS on Apple hardware not by matching its feature list but by exploiting what OBS structurally can't: unified-memory zero-copy from capture to encode (OBS round-trips through generic GL/D3D abstractions), dedicated media-engine encoders for free parallel outputs (program + ISO per source + stream at once), Vision/Core ML on the ANE for real-time person segmentation without a green screen, ScreenCaptureKit's per-app audio/video capture, and an ecosystem story — Continuity, Bonjour pairing, Shortcuts, Stream Deck, watch/phone tally — that makes multi-device production feel like AirPods pairing instead of network engineering. And where OBS's output is a black box, Prism records broadcast *and* per-source ISO with shared timecode and exports a ready-cut Final Cut multicam project — the live show and the post workflow are the same asset.

---

## 2. FEATURE SET

Tags: **[MVP]** = walking skeleton must have it · **[v1]** = first public release · **[v2+]** = stretch.

### 2.1 Ingest
| Feature | Why | Tier |
|---|---|---|
| Mac cameras (built-in/USB/UVC capture cards) via `AVCaptureSession`, full format/fps/resolution control | Table stakes; UVC means cheap HDMI capture cards work day one | MVP |
| Microphones incl. aggregate devices, per-device format control | Table stakes | MVP |
| Display / window / **app** capture via ScreenCaptureKit, with cursor toggle, exclusions | SCK is GPU-native (IOSurface out), far better than OBS's capture on Mac | MVP |
| **Per-app audio** capture (SCK) + **system audio** (CATap, macOS 14.2+) | The #1 Mac OBS pain point; no BlackHole/loopback drivers ever | MVP |
| Continuity Camera as a source (zero-setup single iPhone) | Free quality win; the on-ramp before the companion app | MVP |
| **Prism Camera (iOS companion)**: N simultaneous iPhones/iPads streaming HEVC over LAN | The headline feature; see §3.4 for transport | v1 |
| Companion pro controls: lens select, exposure/focus/WB lock, torch, orientation lock, mic on/off, thermal+battery telemetry, remote tally | An angle you can't trust or control isn't an angle | v1 |
| Companion multicam: front+back of one iPhone as two sources (`AVCaptureMultiCamSession`) | Two angles per device; nobody else does this | v2+ |
| Media sources: looping video files, images, GIFs | Bumpers, BRB screens | MVP |
| Browser source (WKWebView → layer capture) | Alerts/overlays ecosystem (StreamElements etc.) works day one | v1 |
| Text/title source (SF fonts, live variables: clock, counters) | Lower-thirds without a browser | v1 |
| NDI input (plugin) | Interop with existing studios | v2+ |
| Remote guests over WebRTC (invite link, like vdo.ninja) | Podcast/interview shows | v2+ |
| Syphon in/out | Mac VJ/graphics ecosystem | v2+ |

### 2.2 Scenes & Compositing
| Feature | Why | Tier |
|---|---|---|
| Scenes with unlimited layers; per-layer transform/crop/rotate/opacity | Core model | MVP |
| Canvas manipulation with snap guides, alignment, safe areas | Keynote-grade direct manipulation, not OBS's fiddly grab-handles | MVP (guides v1) |
| Preview/Program monitors with **Cut** | Broadcast-correct switching | MVP |
| Transitions: dissolve, dip-to-color, wipe, push; custom Metal transitions | Production polish | v1 |
| Nested scenes (scene-as-source) | Composability; layouts reference layouts | v1 |
| PiP layout presets (1-tap side-by-side, corner cam, etc.) | 90% of real scenes are 4 layouts | MVP |
| Multiview monitor (all scenes + program grid, second display) | Real switching needs to see everything | v1 |
| Scene collections/profiles (per-show setups) | Streamers run multiple shows | v1 |
| Per-scene audio-follow rules (which sources unmute on switch) | Audio must follow video or shows sound wrong | v1 |
| **Keyframed layer animation** (position/scale/opacity/crop tracks, easing curves, springs) | Motion-graphics feel without post | v1 |
| Layer enter/exit animations + animated scene transitions built on the same keyframe engine | One animation system, not three | v1 |
| **Auto-Director**: Vision-driven auto-switch/auto-frame on speaker | The "built the way Apple would" showpiece | v2+ |

### 2.3 Effects & Filters
| Feature | Why | Tier |
|---|---|---|
| Chroma/luma key (custom Metal shader: despill, edge feather, matte view) | Green-screen table stakes, done at Metal speed | v1 |
| **Person segmentation** background remove/blur/replace (Vision, ANE) — no green screen | The single most-demoed differentiator vs OBS | v1 |
| 3D LUTs (.cube) + exposure/contrast/temp/tint wheels (Core Image on Metal) | Camera matching across iPhone/Mac/UVC sources is mandatory in multicam | v1 |
| Sharpen / temporal denoise | Cheap quality wins on webcams | v1 |
| Shape/image/alpha masks per layer | Circular cam bubbles, vignettes | v1 |
| **Auto color** (auto white-balance + exposure per source, temporally smoothed) | One-click fix for mismatched webcams/phones — DaVinci-style "auto color" | v1 |
| **Shot match** (statistical color transfer: match any camera to a reference camera) | Multicam only looks professional when the angles match | v1 |
| **3D relight** (depth-map-driven virtual lights: key/fill/rim with position/color/intensity, auto presets, face-brighten) | DaVinci "Relight"-class feature, on-device via Core ML depth + Metal shading | v2+ (engine skeleton now) |
| Face-aware auto-framing (Center Stage-like crop via Vision) | Keeps solo creators framed | v2+ |
| Core ML filter plugin point (bring-your-own model: style, upscale) | Extensibility without shipping everything | v2+ |

### 2.4 Audio
| Feature | Why | Tier |
|---|---|---|
| Mixer: per-source gain/pan/mute/solo, peak + **LUFS** meters | Broadcast audio, not a volume slider | MVP (LUFS v1) |
| Per-source A/V sync offset (± ms) | Every capture chain has different latency | MVP |
| Monitoring bus: selectable output device, per-source monitor toggle | Hear the mix without feeding it back | v1 |
| Sidechain ducking (music under voice) | Podcast/stream standard | v1 |
| Channel inserts: EQ/compressor/limiter built-in, **3rd-party AUv3** hosting | The Mac's audio-plugin ecosystem is a moat OBS ignores | v1 |
| Master chain: loudness target (−14 LUFS) + true-peak limiter | Platforms normalize; hit the target on purpose | v1 |
| Voice isolation / ML noise removal per source | Apple's own DSP, one toggle | v1 |
| **Multitrack recording** (each source on its own track in the file) | Fix the mix in post | v1 |

### 2.5 Output & Streaming
| Feature | Why | Tier |
|---|---|---|
| Record program: H.264/HEVC (media engine), crash-safe fragmented writing (`AVAssetWriter`) | Never lose a show to a crash | MVP |
| ProRes recording (422/LT/Proxy, hardware on Pro/Max/Ultra) | Edit-grade masters; OBS can't touch this | v1 |
| **Virtual Camera** — CoreMediaIO Camera Extension, feeds Zoom/Meet/FaceTime/Safari | The daily-driver feature; also the riskiest, so it's in the skeleton | MVP |
| RTMP(S) streaming (HaishinKit), presets for Twitch/YouTube/etc. | Table stakes | MVP |
| SRT output (libsrt) | Modern contribution protocol, better on bad networks | v1 |
| Multi-destination simultaneous streaming (parallel encodes on media engines) | Restream without a cloud service | v1 |
| **ISO recording**: clean per-source recordings + program, shared timecode | The pro moat | v1 |
| **FCPXML multicam export**: one click → Final Cut project, all ISOs aligned | Live show and post workflow become one asset | v2+ (design for it in v1 file layout) |
| Replay buffer + instant-replay source | Gaming/sports standard | v1 |
| Stream health HUD: bitrate, dropped frames, congestion, encoder load, thermals | Trust on air | MVP-basic, v1-full |
| Simultaneous horizontal + vertical programs (two compositions, one show) | TikTok/Shorts + YouTube in one pass; creators beg for this | v2+ |
| HDR (P3/HLG) pipeline end-to-end | iPhone shoots HDR; eventually the pipeline should honor it | v2+ |

### 2.6 Control & UX
| Feature | Why | Tier |
|---|---|---|
| Full keyboard control + command palette (⌘K) | Live = no mousing | v1 |
| Menu bar extra: on-air status, quick scene switch, panic mute | Control without window focus | v1 |
| Stream Deck plugin + MIDI learn (CoreMIDI) | The de-facto streamer control surfaces | v1 |
| iPhone/iPad remote: tally + scene switching (same transport as camera app) | The companion app doubles as a switcher | v2+ |
| On-air OS integration: Focus mode on stream start, confirm-before-end-stream, dock badge | "Safe by default" — never end a stream by accident | v1 |
| Preflight "Broadcast Check": bandwidth test, encoder test, disk space, thermal headroom | OBS fails silently; Prism rehearses | v1 |
| Onboarding: Bonjour auto-discovery of iPhones, QR pairing, push "Use as camera?" | Multi-device setup must feel like AirPods | v1 |
| VoiceOver/accessibility on all controls | Apple-native means accessible | ongoing |

### 2.7 Automation & Scripting
| Feature | Why | Tier |
|---|---|---|
| App Intents → Shortcuts: start/stop stream & record, switch scene, mute, set text source | Automation for free (Focus, NFC tags, schedules) | v1 |
| Event triggers: on-stream-start / on-scene-switch → run action/Shortcut | Self-driving shows (start recording when live, etc.) | v1 |
| **OBS-WebSocket-compatible local API** | Every existing streamer tool/bot works with Prism day one — adopt the ecosystem instead of fighting it | v1 |
| JavaScriptCore scripting + signed plugin SDK (sources/filters/outputs) | Long-term ecosystem | v2+ |

---

## 3. ARCHITECTURE

### 3.1 Process topology
```
┌────────────────────────── Mac ──────────────────────────┐
│  Prism.app (SwiftUI shell + Engine)                      │
│  ├─ Engine.framework  (no AppKit; portable core)         │
│  │   ├─ SourceGraph      (capture adapters)              │
│  │   ├─ HouseClock/Sync  (timing authority)              │
│  │   ├─ Compositor       (Metal)                         │
│  │   ├─ AudioEngine      (AVAudioEngine graph)           │
│  │   └─ OutputHub        (encoders + writers + senders)  │
│  ├─ PrismCameraExtension.appex (CMIO camera extension,   │
│  │      separate sandboxed process, frames via IOSurface)│
│  └─ Local control server (WebSocket, OBS-ws compatible)  │
└──────────────────────────────────────────────────────────┘
            ▲  QUIC over LAN (Bonjour-discovered, TLS)
┌───────────┴───────────┐   × N devices
│ Prism Camera (iOS)    │
│ AVCaptureSession →    │
│ VideoToolbox HEVC →   │
│ QUIC datagrams + ctrl │
└───────────────────────┘
```

### 3.2 Video pipeline (per frame)
```
capture → house-timestamp → per-source mailbox → compositor (Metal) → program texture
                                                                        ├→ VT encode #1 → RTMP/SRT
                                                                        ├→ VT encode #2 → AVAssetWriter (record)
                                                                        ├→ IOSurface queue → CMIO extension (virtual cam)
                                                                        └→ preview CAMetalLayer(s)
ISO taps: each source's raw buffers → dedicated VT encode → per-source AVAssetWriter (v1)
```

**Framework per component**
- **Capture (Mac cams/mics):** `AVCaptureSession` / `AVCaptureDevice` (incl. Continuity Camera, UVC devices).
- **Screen/window/app + app audio:** ScreenCaptureKit (`SCStream`, `SCContentFilter`); system-wide audio via CATap (`AudioHardwareCreateProcessTap`, macOS 14.2+).
- **iOS ingest:** companion app — `AVCaptureSession`(/`AVCaptureMultiCamSession`) → VideoToolbox HEVC low-latency encode → **Network.framework QUIC** (see §3.4).
- **Compositing:** Metal (custom render pass) + Core Image (backed by the same Metal device/command queue) for filter chains; Vision (`VNGeneratePersonSegmentationRequest` / instance masks) on the ANE; Core ML for pluggable models.
- **Audio:** AVAudioEngine graph (mixer nodes per source, AUv3 inserts, taps for meters); `AVAudioConverter` for per-source drift-compensating resample.
- **Encode:** VideoToolbox (`VTCompressionSession`) — explicit, not AVAssetWriter's implicit encode, so one encode policy serves stream/record/ISO alike.
- **Record:** `AVAssetWriter` in passthrough mode, fragmented/movie-fragment writing for crash safety.
- **Stream:** HaishinKit (RTMP/RTMPS), libsrt via C interop (SRT).
- **Virtual cam:** CoreMediaIO Camera Extension (`CMIOExtensionProvider`), installed via SystemExtensions framework. (Legacy DAL plug-ins are deprecated/dead — extensions are the only forward path.)

### 3.3 Timing model — the house clock
Everything hangs off one decision: **all media is timestamped in house time** (the Mac's host clock, `CMClockGetHostTimeClock()`), from the moment of capture.

- Mac sources already deliver host-clock PTS.
- iOS devices run continuous clock sync (§3.4) and translate capture timestamps to house time *before* sending.
- The compositor is **pull-based**: a render loop fires at output fps (CVDisplayLink-driven or a dedicated timer thread); at each tick with deadline `T`, it takes from each source's mailbox the newest frame with `pts ≤ T − compensation(source)`.
- Two sync modes, user-visible: **Aligned** (compensation = latency of the slowest source, everything lip-synced, adds ~100 ms pipeline delay) vs **Fastest** (each source shown ASAP; fine for screen-shares, wrong for multicam of one person). Default: Aligned when any iOS source is live.
- **Audio is master.** Video aligns to the audio mix timeline; per-source audio drift is absorbed by micro-resampling (AVAudioConverter with a slowly-adapting rate), never by dropping samples.
- Mailboxes are **latest-wins, depth 2–3** (lock-free ring buffers). Live compositing never queues deep; ISO recording taps the source *before* the mailbox with a real FIFO so recordings drop nothing even when the live mix drops.

### 3.4 iOS transport — decision and rationale
**Choice: custom protocol over QUIC (Network.framework) — control on a reliable stream, media in unreliable datagrams, HEVC from VideoToolbox's low-latency rate-control mode. Bonjour for discovery, QR/PIN pairing with pinned certs.**

Why not the alternatives:
- **NDI**: closed SDK + licensing, ~100 ms+ typical, no control over rate adaptation, un-Apple deployment. Fine later as an interop *plugin*, wrong as the backbone.
- **WebRTC**: right latency class, but you inherit a huge C++ stack, SDP/ICE machinery built for NAT traversal you don't need on a LAN, and its clock/jitter internals fight you when you want *house-clock* authority. Save it for remote guests (v2+), where NAT traversal is the actual problem it solves.
- **SRT**: built for lossy WAN contribution; its latency buffer floor (~120 ms+) and TS muxing are wrong for LAN camera feeds. Keep as an *output* protocol.
- **MultipeerConnectivity**: opaque transport selection, throughput ceilings, notoriously flaky under sustained load. No.
- **Raw UDP/RTP**: viable fallback, but you hand-roll TLS, multiplexing, and connection migration that QUIC gives free. Keep as plan B if QUIC datagram perf disappoints on real devices.

Protocol sketch (`_prism._udp` via Bonjour):
- **Control stream (reliable):** hello/capabilities, session config (codec, resolution, fps, target bitrate), camera control (lens/exposure/torch), tally state, stats, keyframe requests.
- **Clock stream:** ping bursts (8 pings, median offset, outlier-rejected) at connect and every ~2 s; skew tracked by linear regression → device translates capture PTS to house time with sub-millisecond LAN accuracy (lip-sync detectability threshold is ~45 ms; we'll be 40× inside it).
- **Media datagrams (unreliable):** HEVC Annex-B NALUs, sequence-numbered, frame-boundary flagged. Loss policy: P-frame loss → decoder freezes on last good + immediate keyframe request; sustained loss → receiver feedback drops the encoder bitrate rung (ladder: 20/12/8/5/3 Mbps). Optional XOR FEC for marginal Wi-Fi.
- **Audio:** AAC-ELD (FaceTime's low-latency codec) in datagrams, timestamped on the same clock.
- iPhone-side budget: capture (16.7 ms @60) + low-latency HW encode (~5–10 ms) + packetize/send (<5 ms) + adaptive jitter buffer (2–4 frames, 33–66 ms) + HW decode (~5 ms) → **glass-to-composite ≈ 80–120 ms**, stable.

### 3.5 Performance model
- **Zero-copy or die:** every video buffer is a `CVPixelBuffer` backed by an IOSurface from birth (capture) to death (encoder input / CAMetalLayer / extension). `CVMetalTextureCache` wraps buffers as Metal textures; on Apple Silicon unified memory this is a pointer exchange, not a blit. CPU never touches pixels; any code calling `CVPixelBufferLockBaseAddress` on the hot path is a bug.
- **Pixel formats:** sources arrive as native `420f` (bi-planar YUV); the compositor samples YUV directly in the fragment shader (no pre-conversion pass) and renders the program as BGRA8 (P010/HDR is the v2+ fork). Program texture feeds all encoders without conversion (VT accepts BGRA; media engine converts in hardware).
- **One fused pass:** a scene renders as one Metal render pass — layers are textured quads drawn back-to-front, per-layer effects (key, LUT, mask) live in the fragment shader via function constants; only genuinely multi-pass effects (blur, temporal denoise) get their own pass. Budget: **< 4 ms GPU at 1080p60, < 8 ms at 4K60**.
- **Segmentation off the render path:** Vision runs on the ANE at ~15–30 fps into a matte texture the shader samples with temporal smoothing — the render loop never waits on ML.
- **Threading:** capture callbacks on their own serial queues → write mailboxes (lock-free); one dedicated real-time render thread owns the compositor; VT encode is async with its own callbacks; writers on per-output queues; UI reads state via snapshots (Swift 6 strict concurrency, engine actors + `@unchecked Sendable` ring buffers at the two hot boundaries, justified and tested).
- **Encoders in parallel are ~free:** M-series media engines handle program + N ISO encodes + a second stream rung in hardware; the constraint is write bandwidth, not CPU.
- **Latency budget, program glass-to-glass (1080p60):** Mac cam ~8–25 ms · SCK ~1 frame · compositor <4 ms · VT encode 5–15 ms · virtual cam +1 frame (≈ 60–90 ms total); RTMP adds network+player buffering (seconds, platform-side); iOS sources 80–120 ms, which Aligned mode makes the whole program's reference.
- **Measurement is a feature:** `os_signpost` on every stage boundary from day 1; a perf HUD in debug builds; Instruments templates checked into the repo; soak test = 8-hour 4-source run with zero dropped program frames on a baseline M1.

### 3.6 Virtual camera plumbing
The CMIO extension is a separate, sandboxed, always-loadable process. Keep it **dumb**: it exposes one source stream (the "Prism Camera") and one sink; the app renders program frames into an IOSurface pool and pushes via the sink stream (CMSampleBuffers carrying IOSurfaces — still zero-copy across the process boundary). When the app isn't running or isn't sending, the extension serves a branded placeholder card at 30 fps so client apps never stall. Gotchas owned up front: SystemExtensions activation UX (user approval in Settings), notarization + entitlements, upgrades (extension version handshake), and the fact that FaceTime/Zoom/Chrome each negotiate formats differently — ship a compatibility matrix test rig (v0 spike exercises Zoom, Meet/Chrome, FaceTime, QuickTime).

---

### 3.7 Animation & smart color/light (added 2026-07-07 at operator request)
- **Animation engine (PrismAnimation):** a pure keyframe system — typed tracks (`position/size/opacity/crop/…`), easing (linear/bezier presets/spring), sampled in *house-time seconds*. It never renders: `AnimatedScene.evaluate(at:)` returns a plain `Scene` with layer overrides, so the compositor stays dumb and the animation system is 100% unit-testable. Scene transitions and layer enter/exit moves are the same engine driving transform/opacity tracks; a `TransitionCurve` feeds the compositor's future mix stage.
- **Color/light stage (PrismColor):** a per-source `VideoFrame → VideoFrame` GPU filter chain that runs *before* compositing (DESIGN §3.2 stays unchanged — this is a source-stage filter). Components: manual grade (exposure/contrast/saturation/temp/tint), 3D LUT (.cube), **AutoColor** (gray-world WB + histogram exposure, temporally smoothed so it never pumps), **ShotMatch** (mean/σ color transfer in a perceptual space against a reference frame), and **Relight** (depth map → normals → N virtual Lambertian+specular lights in a Metal shader; depth from a pluggable `DepthProvider` — Core ML Depth-Anything-class model, run at reduced rate off the render path like segmentation). Analysis (histograms/stats) runs on downsampled frames at a few Hz, never per-frame at full res.

### 3.8 Radios: what carries what (added 2026-07-07, operator question)
- **Video NEVER travels over Bluetooth.** BLE sustains ~0.1–1 Mbps in practice and BT Classic ~2 Mbps; 1080p60 HEVC needs 8–12 Mbps per device. Physics closes that door — every product that "connects by Bluetooth" (Continuity Camera included) uses BT only to find/wake the peer, then moves data over Wi-Fi.
- **Role split:** Bluetooth LE = *proximity discovery + pairing assist + wake* (v2: BLE advertisement lets the Mac show "your iPhone is nearby — pair?" before any Wi-Fi association, and can nudge a sleeping companion app awake, mirroring Continuity Camera's model). Wi-Fi/Ethernet = *all media transport* (QUIC, §3.4). v1 pairing bootstrap = short code / QR (PSK-derived TLS 1.3, HKDF over the code); BLE bootstrap layers on later without touching the transport.
- **No shared router needed (fallback):** Network.framework's `includePeerToPeer` enables AWDL (peer-to-peer Wi-Fi, the AirDrop link) so a phone can feed the Mac with no infrastructure Wi-Fi at all — venue-proof. Caveat: AWDL duty-cycles the radio; expect more jitter than infrastructure Wi-Fi, so the jitter buffer must adapt (already designed) and the UI should badge the link type.
- **Link budget sanity:** 4 devices × 12 Mbps ≈ 48 Mbps sustained — comfortable on Wi-Fi 5/6 infrastructure; the Mac on Ethernet removes its own radio contention. The stats channel already reports per-peer loss/jitter → the bitrate ladder absorbs congested networks.

## 4. THE HARD PARTS

**1. Multi-device low-latency transport + sync (the make-or-break).**
Risk: jitter spikes, Wi-Fi asymmetry, encoder queue buildup on thermally-throttled iPhones, clock drift.
Attack: own the whole path (§3.4) — low-latency VT rate control (no B-frames, capped queue), receiver-driven bitrate ladder with loss/jitter feedback, adaptive jitter buffer that *reports* its depth into the sync compensator, PTP-lite clock with continuous skew regression, thermal telemetry from the device driving proactive rung-down before the throttle hits. Build the network simulator harness (Network Link Conditioner profiles + packet-loss replay) in phase 0, not after bugs arrive. Fallback ladder: QUIC datagrams → raw UDP → (worst case) QUIC streams with shallow buffers.

**2. The CMIO Camera Extension.**
Risk: it's a poorly-documented, separately-sandboxed process with fussy activation UX; most teams' first extension takes weeks of dark debugging.
Attack: phase-0 spike that does nothing but pump a test pattern to Zoom/Meet/FaceTime; keep all intelligence in the app (extension = IOSurface relay + placeholder); version-handshake protocol for upgrades; automated client-app compatibility rig. Accept the user-approval flow and design onboarding around it honestly.

**3. Sustained 1080p60→4K60 pipeline performance.**
Risk: death by a thousand copies — one accidental CPU readback or format conversion and the budget's gone; thermal creep on fanless Macs over hours.
Attack: the zero-copy invariants in §3.5 enforced by debug assertions (fail loudly if a non-IOSurface buffer enters the graph); single fused render pass; signpost-gated CI perf tests (regression = build failure); 8-hour soak with thermal logging as a release gate.

**4. A/V sync across devices with independent, drifting clocks.**
Risk: lip-sync drift that appears after 40 minutes; audio pops from correction jumps.
Attack: house-clock authority + audio-as-master (§3.3); drift absorbed by continuous micro-resampling (parts-per-million rate nudges, never sample drops); per-source manual offset trim; a built-in **calibration tool** — clap in front of any camera, Prism detects the transient in audio and the motion spike in video and sets the offset automatically. Ship the sync-mode fork (Aligned/Fastest) rather than pretending one latency policy fits all.

**5. System/app audio capture across macOS versions + permission choreography.**
Risk: SCK app-audio and CATap system-audio have different OS floors, entitlements, and TCC prompts; a first-run that stacks five permission dialogs (camera, mic, screen, system audio, system extension) feels hostile.
Attack: capability-tiered audio backend (SCK per-app audio everywhere; CATap where available; degrade gracefully with explicit UI, never silent failure); a **staged onboarding** that requests each permission in context ("Add your first screen source → now macOS will ask…") with a preflight checklist showing red/green per capability.

---

## 5. TECH STACK + PHASED BUILD PLAN

**Stack:** Swift 6 (strict concurrency) everywhere · SwiftUI shell with AppKit escape hatches (`NSViewRepresentable` MTKView/CAMetalLayer monitors, NSToolbar) · Metal 3 + MSL shaders · Engine as a platform-agnostic framework (no AppKit imports) shared with the iOS companion · C interop for libsrt · XCTest + golden-frame image tests for shaders + network-sim harness.

**Build vs buy:**
- **Build** (it's the product): compositor, house clock/sync, iOS transport protocol, camera extension, audio graph glue, ISO/recording layer, control API.
- **Buy/adopt** (commodity): HaishinKit (RTMP/RTMPS), libsrt (SRT), Stream Deck SDK, .cube LUT parsing (trivial, could build), OBS-websocket *protocol spec* (compatibility, not code).
- **Explicit non-goals early:** Windows/Linux, cloud services, WebRTC guests (until v2+), building our own RTMP stack.

**Phase 0 — Kill the risks (spikes, ~2–3 weeks of focused agent-time):**
1. CMIO extension pumping SMPTE bars into Zoom/Meet/FaceTime.
2. iPhone → Mac QUIC HEVC feed, 1080p60, measured <120 ms glass-to-glass, surviving Link-Conditioner abuse.
3. SCK window + AVCapture camera composited in one Metal pass at 4K60 with signpost timings.
Exit: all three demos on real hardware, or the design forks *now* (that's what spikes are for).

**Phase 1 — Walking skeleton (MVP):** everything tagged [MVP] above: 2+ local sources (camera, screen/window/app, media files, Continuity Camera), scenes with transform + PiP presets, preview/program cut, audio mixer with per-source offset, program record (crash-safe HEVC), RTMP stream, **virtual camera**, health HUD-basic. One binary, end-to-end, dogfooded on real calls/streams daily from here on.

**Phase 2 — The headline (v1 core):** Prism Camera iOS app (N devices, pro controls, tally), Aligned sync mode + calibration tool, chroma key, person segmentation, LUTs, transitions, browser + text sources, ducking + AUv3 inserts + LUFS, SRT, multi-destination, ISO recording + multitrack audio, replay buffer.

**Phase 3 — The ecosystem (v1 ship):** Stream Deck + MIDI, App Intents/Shortcuts, event triggers, OBS-websocket-compatible API, command palette + menu bar + preflight Broadcast Check, onboarding QR pairing, scene collections, multiview.

**Phase 4 — Stretch (v2+):** FCPXML multicam export, vertical+horizontal dual program, WebRTC guests, NDI/Syphon plugins, Auto-Director, keyframed motion, HDR pipeline, iPad remote/companion multicam, plugin SDK.

---

## 6. UX

**Layout (single window, three zones + drawer):**
- **Left rail — Scenes:** vertical list of scene thumbnails (live-updating), drag-reorder, right-click duplicate/nest. Below it, the **Sources list** for the selected scene with visibility eyes and lock toggles.
- **Center — Monitors:** Program (always) and Preview (toggleable; solo creators often run single-monitor "what you see is live" mode). Between them, the **Cut / Auto** transition controls and duration. Monitors are real CAMetalLayers — pixel-accurate, EDR-aware, with optional safe-area/grid overlays. Direct manipulation *on the monitor*: drag/resize/crop layers with Keynote-style snap guides — not OBS's fiddly handles.
- **Right rail — Inspector:** context-sensitive (Keynote/Final Cut pattern). Select a source → its capture settings, filters stack, transform, audio trim. Select a scene → transition override, audio-follow rules. No modal settings maze — *the settings dialog is where UX goes to die in OBS; Prism has inspectors.*
- **Bottom drawer — Mixer:** channel strips (fader, pan, mute/solo, meters with LUFS, insert slots, monitor button), master strip with loudness target readout.
- **Top bar — Transport:** REC / STREAM / VCAM as three independent, clearly-stateful toggles with elapsed timers, health glyphs (bitrate, dropped frames, thermal), and the ⌘K command palette.

**Sizing & placement:**
- **Mac window:** minimum ~1100×700 (sidebar 240 + monitor 16:9 + inspector 280); sidebar and mixer drawer collapse first as the window shrinks; monitors letterbox, never crop. Program can pop out full-screen onto a second display (client-monitor mode). The app lives in **/Applications** (required for system-extension activation), with the menu-bar extra as the always-there control point.
- **iOS companion:** iPhone = viewfinder-first single column (tally card replaces the viewfinder when live); iPad = same app (device family 1,2) with room for a settings side panel; all layouts safe-area-driven, portrait and landscape both supported since a camera rig can mount either way. Footprint is small (tens of MB); the Mac side's real disk consumer is recordings (~5 GB/hour 1080p60 HEVC program; ISO multiplies by source count — the preflight check warns on disk headroom).

**What makes it feel Apple-native (and better than OBS):**
- **Pairing like AirPods:** iPhone with Prism Camera installed appears in Sources the moment it's on the LAN ("your iPhone — Tap to add"); first pair via QR/PIN; thereafter it just shows up. Tally on the phone screen + optional watch tap.
- **Safe by default:** confirm-before-end-stream, on-air triggers a Focus mode, panic-mute hotkey, crash-safe recordings, Broadcast Check preflight before going live.
- **System citizenship:** menu bar extra, dock badge while live, Shortcuts actions, VoiceOver, native full-screen/Stage Manager behavior, SF Symbols, system materials — and it respects the OS's camera/mic indicators rather than fighting them.
- **Honest performance:** a health HUD that tells the truth (encoder load, network headroom, thermal state) instead of OBS's silent frame-dropping.

---

## 7. FIRST BUILD — the single highest-leverage thing

**Build the zero-copy Metal compositor core with the house-clock timing model, proven end-to-end by the thinnest possible loop: one camera + one ScreenCaptureKit source → composited scene → virtual camera extension, visible in a real Zoom call.**

Why this and not the iOS transport or streaming first: every feature in this document — every source type, effect, output, and the iOS feeds themselves — plugs into the compositor's frame contract (IOSurface-backed buffers, house-time PTS, mailbox semantics, pull-based render loop). Those decisions are effectively **unretrofittable**: get the clock or copy semantics wrong and every later component inherits the mistake. The virtual camera rides along because it's the highest-risk *deployment* artifact (system extension) and the fastest path to daily dogfooding — the moment Prism is your camera in real calls, every pipeline bug becomes visible within a day. Streaming is commodity risk (HaishinKit is proven), and the iOS transport, while the headline, *depends on* the timing model existing — so it's the phase-0 spike that runs in parallel, and the first thing the finished core ingests.

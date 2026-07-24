# Prism — World-Class Features + AppEngine Decomposition Blueprint (Fable, 2026-07)

Working doc (gitignored). Grounded in the real code. Two parts: what to build next, and how to
decompose the AppEngine god-object safely.

## Part 1 — World-class features (build order)

1. **Chat / platform layer — BUILD NOW (S–M, highest ROI/effort).** Twitch chat (unauth IRC/WS)
   + YouTube live-chat poll → a native styled overlay source (reuse TextSource/motion-gfx overlay
   seams, AppEngine.swift:8803,8862) + a chat-velocity HighlightSignal into Director's Cut
   (ingestHighlight AppEngine.swift:9699/9707) + event-triggered stingers (reactive-trigger 9932,
   armed-stinger memes 8495). Almost entirely composition of verified parts. Ship this month.
2. **Remote Guests ("Green Room") — the big market bet (L; gate on Phase 6).** WebRTC/WHIP browser-join
   guest → lands as a normal source → per-source ISO (AppEngine.swift:4311) gives local-quality guest
   recording FREE (Riverside's whole pitch, natively). A `GuestController` is a sibling of LinkServer
   (same downstream contract: FrameMailbox + mixer channel + ActiveSource; add-source pattern 2780-2802;
   mix-minus return via master fan-out 2026). Catch: WebRTC (ICE/DTLS-SRTP) needs libwebrtc/LiveKit —
   first external dep + TURN/NAT story. Changes WHO Prism is for. Gate on the app being installable (Phase 6).
3. **NDI in/out (M) — mandatory pro checkbox.** Output = one more ProgramFanOut consumer (vcam pattern,
   VirtualCameraController.swift:87); input = a CameraSource-like class + mailbox (2780-2802). SDK + license.

Deprioritized (Fable pushback): voice-control (false-trigger liability mid-show; hotkeys/MIDI cover it),
live-translation (niche). The real world-class gap is partly boring: **Phase 6 notarized/installable build**
— run Chat parallel to Phase 6, gate Guests on it.

## Part 2 — AppEngine decomposition (safe, phased)

**The contract (proven by VirtualCameraController):** @Published never moves (controller pushes back via
`on…` callbacks set in init, same main-actor ordering); public API becomes thin forwarders; controllers are
@MainActor classes owned by composition with infra injected; `_test_*` seams forward too; ONE extraction per
commit, full suite green before+after. For state a controller must READ (hdrEnabled/canvasConfig/didShutdown),
inject **closures** `() -> Bool`, NOT an AppEngine back-ref. No protocol layer until a test needs a fake.

**The spine — do NOT extract:** `fanOut` (644, inject into every output), `renderLoop`+build/rebuild
(643,2278,6782) — controllers hold closures not loop refs, `scene.didSet` (839-863, 5 ordered side-effects —
the #1 silent-break risk), `activeSources` (790, 89 internal + ~13 view refs — mirror only, one writer),
`isOnAir` (1950). Correction to prior framing: streaming and replay do NOT share an encoder (replay has its
own, 4630); the only sharing is streamEncoder→RTMP+broadcaster (5454-5482) — contained in one future controller.

**Extraction order:**
- **Wave 1 (S each, ~750L out, ~zero risk):** Sound (1169-1192;7658-7875), Proximity (1903-1914;6618-6669),
  Screen-browser/BroadcastCheck/FCPXML (1741;3854,4720-4900), MIDI (1886-1901;6400-6618, dispatch→injected closure).
- **Wave 2 (outputs — best test coverage, real de-risk):** ExternalOutputBarrier (lift teardown registry
  1145-1155 first) → RecordingController (#5, ~900L: recorder/ISO/multitrack/replay; interface ≈ fanOut.setRecorder/
  setReplayEncoder + injected canvas/hdr closures; exposes isRecording/replayArmed queries) → StreamingController
  (#6, ~650L: encoder+RTMP+broadcaster+StreamOutputState.reduce; engine keeps @Published streamOutputState mirror).
- **Wave 3 (sources — highest risk; do NOT move activeSources):** Montage (7,~640L) → MemeBoard (8,~900L,
  memeBaseScene injected, didSet stays) → Source factories (per-family add-paths take the tap bundle at
  construction; engine still calls register()) → LinkController (9) → Overlays (10).
- **Wave 4:** ProductionSignals (Director's Cut+auto-director+captions+reactive, 11) → SceneController (12, LAST;
  consider leaving scene storage+didSet on engine permanently, extract only transition scheduling).

**End state:** AppEngine ≈ 1,500–2,000 lines = the composition root (init/wiring, render build/rebuild, scene
crossroads, source registry, @Published mirrors, shutdown).

**Watch-list:** scene.didSet ordering; HDR/canvas rebuilds re-vend loop/compositor (closures only);
streamEncoder→2 sinks move atomically; activeSources one-writer; tap capture in onFrame (2786) — inject taps,
don't recreate; didShutdown guards (inject isShutdown closure or resurrect the attach-after-shutdown bug class).

**Ratchet:** CI check that AppEngine.swift line count only decreases; each PR proven by untouched suite +
before/after forwarder-signature grep.

**Sequencing:** Wave 1 + RecordingController first, StreamingController next → ~2,500L out, riskiest surface
(outputs) behind interfaces with best tests, and Guests slots in as a NEW sibling controller instead of
AppEngine line 10,015+ — the real reason to decompose now, before the next big feature.

# PrismVirtualCam

The "Prism Camera" virtual camera (DESIGN.md §3.6, hard-part §4.2). Same method OBS uses on
macOS — a CoreMediaIO **Camera Extension** (`.systemextension`) — with the intelligence kept
in the app: the extension is a dumb IOSurface relay + placeholder generator.

| Piece | File(s) | Runs in |
|---|---|---|
| `PrismVCamConstants` | `PrismVCamConstants.swift` | both processes (shared identity/formats) |
| `PrismExtensionProviderSource` / `PrismVirtualCamExtension.main()` | `Extension/PrismExtensionProviderSource.swift` | extension process |
| `PrismExtensionDeviceSource` (sink→source mirror + placeholder) | `Extension/PrismExtensionDeviceSource.swift` | extension process |
| `PrismExtensionStreamSource` / `PrismExtensionStreamSink` | `Extension/PrismExtensionStreamSources.swift` | extension process |
| `PlaceholderRenderer` (branded SMPTE-ish card, rendered once) | `Extension/PlaceholderRenderer.swift` | extension process |
| `VirtualCameraFeeder` (DAL C-API sink pump) | `VirtualCameraFeeder.swift` | host app |
| `SystemExtensionInstaller` (OSSystemExtensionRequest wrapper) | `SystemExtensionInstaller.swift` | host app |

Data path: compositor program `VideoFrame` → `VirtualCameraFeeder.send()` → CMSampleBuffer
(IOSurface by reference, zero-copy) → sink stream queue → extension mirrors onto the source
stream → Zoom/Meet/FaceTime. No sink client for >0.5 s ⇒ cached placeholder card at 30 fps
so clients never stall.

## Embedding in the Xcode app (integrator checklist)

This SwiftPM library compiles the extension classes but **cannot produce the
`.systemextension` bundle** — that needs an Xcode app project. Steps:

### 1. Create the extension target

File → New → Target → macOS → **Camera Extension**. Name it `PrismCameraExtension`, bundle id
`studio.prism.PrismStudio.vcam` (= `PrismVCamConstants.extensionBundleID` — keep in sync).
Delete the template's provider sources and make `main.swift` exactly:

```swift
import PrismVirtualCam
PrismVirtualCamExtension.main()
```

Link the `PrismVirtualCam` (and transitively `PrismCore`) library product into this target.

### 2. Extension Info.plist

```xml
<key>CMIOExtension</key>
<dict>
    <key>CMIOExtensionMachServiceName</key>
    <string>$(TeamIdentifierPrefix)studio.prism.PrismStudio.vcam</string>
</dict>
```

Rules: the mach service name **must** be prefixed by the team identifier (as above) or by an
app group the extension holds, or registration fails silently (extension launches, no device
appears — the classic dark-debugging trap). The Xcode Camera Extension template also sets
`CFBundlePackageType` = `SYSX` and the principal-class glue; keep those.

### 3. Entitlements

Extension target (`PrismCameraExtension.entitlements`):

```xml
<key>com.apple.security.app-sandbox</key> <true/>
```

Host app (`PrismStudio.entitlements`):

```xml
<key>com.apple.security.app-sandbox</key> <true/>
<key>com.apple.security.device.camera</key> <true/>
```

plus `NSCameraUsageDescription` in the app's Info.plist — opening the DAL sink stream counts
as camera access, so the feeder triggers the camera TCC prompt on first attach. App also
needs `NSSystemExtensionUsageDescription` for the activation prompt.

### 4. Embed the extension in the app

App target → Build Phases → **Embed System Extensions** (destination resolves to
`Contents/Library/SystemExtensions/`). Result inside the built app:

```
PrismStudio.app/Contents/Library/SystemExtensions/studio.prism.PrismStudio.vcam.systemextension
```

`OSSystemExtensionRequest` hard-requires this exact location.

### 5. Signing

- Both targets signed with the **same team**; the app needs the System Extension capability.
- Debug: "Apple Development" certs work only with developer mode (below).
- Distribution: Developer ID + hardened runtime + **notarization**; sysextd refuses
  unsigned/ad-hoc extensions outside developer mode.

### 6. Dev loop (unsigned-ish iteration)

```sh
systemextensionsctl developer on        # allows activation from non-/Applications paths
# build & run the app, call SystemExtensionInstaller.activate()
systemextensionsctl list                # verify: [activated enabled]
systemextensionsctl uninstall <TeamID> studio.prism.PrismStudio.vcam   # reset
```

Without developer mode the .app must sit in `/Applications` before activation. First
activation always lands in **System Settings → General → Login Items & Extensions**
(`Phase.requiresApproval` from the installer) — design onboarding around that honestly
(DESIGN §4.2). Extension logs: `log stream --predicate 'subsystem == "studio.prism"'`.

### 7. Host-side wiring

```swift
let installer = SystemExtensionInstaller()
installer.onPhaseChange = { phase in /* drive onboarding UI */ }
let phase = try await installer.activate()          // .activated

let feeder = VirtualCameraFeeder()
feeder.onStateChange = { state in /* health HUD */ } // .extensionNotInstalled → .feeding
feeder.start()
// per program frame, from the render thread:
feeder.send(programFrame)
```

## Client-app compatibility test matrix (DESIGN §3.6 — run per release)

Each client negotiates formats differently; test **both** rows of the format table
(BGRA index 0, 420v index 1) and both feed states.

| Client | Select camera | App NOT running (expect placeholder card @30fps) | App feeding (expect program @60fps) | Notes |
|---|---|---|---|---|
| Zoom | Settings → Video → Camera → "Prism Camera" | ☐ | ☐ | Zoom caches devices; restart Zoom after first install |
| Google Meet (Chrome) | meet.google.com → Settings → Video | ☐ | ☐ | Chrome enumerates via getUserMedia; check chrome://media-internals for negotiated format |
| FaceTime | Video menu → "Prism Camera" | ☐ | ☐ | FaceTime prefers YUV — exercises the 420v path |
| QuickTime Player | New Movie Recording → camera chevron | ☐ | ☐ | Simplest sanity check; shows raw fps in the record HUD |

Also verify per client: switching the Prism app on/off mid-call swaps placeholder ↔ program
within ~1 s with no client freeze; camera survives extension upgrade (activate over old
version → `.replace`); teardown (`feeder.stop()`) falls back to placeholder, not black.

## Verification status

- **VERIFIED (compile):** every class here builds clean (zero errors / zero warnings) against
  the macOS 15 SDK CMIOExtension + DAL headers; signatures were taken from the SDK headers,
  not memory.
- **UNVERIFIED (runtime):** everything behavioral — device registration, sink→source mirror,
  placeholder cadence, feeder attach, sysext activation UX, and the whole client matrix —
  requires a signed app bundle with the embedded extension (steps above) plus user approval
  and camera TCC. There is no way to exercise a CMIO extension from a SwiftPM library target;
  the phase-0 spike (DESIGN §5) is where this gets proven on real hardware.
- Sink-stream identification uses `kCMIOStreamPropertyDirection == 0` (sink ⇔ DAL "output"
  stream — the CMIOExtension sink properties map to `kCMIOStreamPropertyOutput*`), with a
  fallback to stream order (source added first). This machine has no CMIO devices to probe
  (Mac Studio, no camera), so the direction convention is header-derived and flagged for the
  spike to confirm.

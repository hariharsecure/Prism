# Prism — Signing, Notarization & Real-Hardware Runbook (Phase 6)

This is the one part of getting Prism shippable that needs **you** (an Apple Developer
account + Developer ID). Everything below is prepared so your part is mechanical. Prism
currently builds **ad-hoc signed** (`CODE_SIGN_IDENTITY=-`), which runs on the build
machine but **cannot be installed/run by another user**, and the CoreMediaIO **system
extension** + Keychain items need a real Team ID to activate off the dev box.

The virtual camera is a **CMIO system extension** embedded in the app
(`studio.prism.PrismStudio.vcam`), so this is a two-target signing job (app + extension),
and system extensions **must be notarized** to activate outside developer mode.

---

## 0. Prerequisites (you)
- An **Apple Developer Program** membership (individual or org).
- A **Developer ID Application** certificate in your login keychain
  (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application),
  or created at developer.apple.com. Note your **Team ID** (10 chars).
- An **app-specific password** (or an `AuthKey_*.p8` App Store Connect API key) for
  `notarytool` — appleid.apple.com → Sign-In & Security → App-Specific Passwords.
- Store the notary credentials once so the commands below can reference a profile:
  ```sh
  xcrun notarytool store-credentials PrismNotary \
    --apple-id "<your-apple-id>" --team-id "<TEAMID>" --password "<app-specific-pw>"
  ```

## 1. Entitlements + bundle IDs (already in the project)
- App: `studio.prism.app`; camera app: `studio.prism.camera`; **vcam system extension:
  `studio.prism.PrismStudio.vcam`** (must equal `PrismVCamConstants.extensionBundleID`).
- The extension's `CMIOExtensionMachServiceName` is `$(TeamIdentifierPrefix)studio.prism.PrismStudio.vcam`
  — with a real Team ID this resolves to `<TEAMID>.studio.prism.PrismStudio.vcam` (today the
  ad-hoc build has no team prefix, which is why it only runs locally).
- Hardened runtime is **disabled** under ad-hoc signing (see the note xcodebuild prints);
  a Developer ID build **must enable hardened runtime** (`--options runtime`).
- Entitlements to confirm before signing: camera/microphone/screen-capture usage, the
  System Extension entitlement (`com.apple.developer.system-extension.install`) on the app,
  and the app-group/mach-service the app ↔ extension use.

## 2. Build a Release (unsigned or dev-signed), then re-sign Developer ID
```sh
cd App
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen
# Build Release with your team so Xcode wires the extension + entitlements:
xcodebuild -project Prism.xcodeproj -scheme Prism -configuration Release \
  -derivedDataPath build/release \
  DEVELOPMENT_TEAM=<TEAMID> CODE_SIGN_STYLE=Automatic build
```
If you sign out-of-band instead, sign **inside-out** (extension first, then the app), deep,
with hardened runtime + a secure timestamp:
```sh
APP="build/release/Build/Products/Release/Prism.app"
EXT="$APP/Contents/Library/SystemExtensions/studio.prism.PrismStudio.vcam.systemextension"
CERT="Developer ID Application: <Your Name> (<TEAMID>)"
codesign --force --options runtime --timestamp \
  --entitlements <ext.entitlements> --sign "$CERT" "$EXT"
codesign --force --options runtime --timestamp \
  --entitlements <app.entitlements> --sign "$CERT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"   # must pass
```

## 3. Notarize + staple (required for the extension to activate)
```sh
ditto -c -k --keepParent "$APP" Prism.zip
xcrun notarytool submit Prism.zip --keychain-profile PrismNotary --wait   # ~1-5 min
xcrun stapler staple "$APP"
spctl -a -vvv --type exec "$APP"    # → "accepted", source=Notarized Developer ID
```

## 4. Verify the vcam extension activates
Install/run the notarized app, toggle the virtual camera on, then:
```sh
systemextensionsctl list            # studio.prism.PrismStudio.vcam → [activated enabled]
log stream --predicate 'subsystem == "studio.prism"'    # extension logs
```
If activation is blocked, the user approves it once in System Settings → Privacy &
Security → "System software … was blocked".

---

## 5. Real-hardware smoke checklist (the acceptance pass — ~20 min)
No human has run Prism on real hardware yet. Run this once, signed, on a real Mac:

- [ ] **Launch clean**: first-run permission prompts (camera/mic/screen/local-network/
      system-extension) appear sanely, not as a malware-looking avalanche.
- [ ] **Real camera**: add a Mac/UVC camera → live in the program monitor; check color/HDR.
- [ ] **iPhone as camera** (PrismLink): pair via QR/PIN over Wi-Fi, confirm tally + video;
      confirm a *wrong* code is rejected (the mutual-auth guarantee).
- [ ] **Record**: H.264/HEVC/ProRes → the file opens, A/V in sync, clean finalize on stop.
- [ ] **Stream**: to a real RTMP ingest (YouTube/Twitch "stream now") → the platform shows
      the stream, audio present, reconnect survives a Wi-Fi blip.
- [ ] **Virtual camera**: select "Prism Camera" in Zoom/Meet/FaceTime → the program shows.
- [ ] **Studio mode**: edit off-air in preview, TAKE with a dissolve → clean on-air cut.
- [ ] **HDR/EDR**: on an HDR display, confirm HLG/P3 looks right (not washed/clipped).
- [ ] **Sustained-load soak (30 min)**: record + stream + vcam at once; watch the new
      perf HUD (`GetStats`) for thermal throttle, RSS slope, dropped frames.
- [ ] **Glass-to-glass latency**: eyeball the camera→program delay; note it.

Anything that fails here is a real bug the headless suite can't see — report it back and
I'll fix it. Everything that passes is a claim we can finally make honestly.

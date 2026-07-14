import SwiftUI

/// Top transport bar (DESIGN §6): REC and VCAM as independent stateful
/// toggles plus the obs-websocket control server. Streaming ships later.
struct TransportBar: View {
    @EnvironmentObject private var engine: AppEngine
    /// Opens the Getting Started guide (hosted by ContentView so the first-run
    /// presenter and this button share one source of truth).
    @Binding var showHelp: Bool
    @State private var vcamPopoverShown = false
    @State private var streamPopoverShown = false
    @State private var isoPopoverShown = false
    @State private var broadcastCheckShown = false
    @State private var midiPopoverShown = false
    @State private var directorPopoverShown = false
    @AppStorage("stream.rtmpURL") private var rtmpURL = ""
    // Codex #8: the primary RTMP stream key is a secret — it lives in the Keychain
    // (loaded on appear, migrated off the legacy `stream.key` UserDefaults entry),
    // NOT in UserDefaults. Held in @State only for the duration of the view.
    @State private var streamKey = ""

    var body: some View {
        // Only the two primary actions (Record, Stream) carry text labels; every
        // secondary control is a clean icon with a .help() tooltip so nothing
        // truncates to a one-letter stub at the 1100 pt minimum window width.
        // Controls are grouped into three clusters (capture · output · tools)
        // with a divider between clusters instead of between every item.
        // The control clusters scroll horizontally so the live-status extras that
        // only appear while RECORDING **and** STREAMING at once (the mono record
        // timer + stream state + bitrate + dropped-append glyphs) can never squeeze
        // the primary Record/Stream labels down to a truncated stub at the 1100 pt
        // minimum width — they stay fully readable and the overflow scrolls instead.
        // help + on-air stay pinned on the right (the ScrollView is greedy, so at a
        // wide window it fills the gap exactly like the old trailing Spacer did).
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Cluster 1 — capture / record
                    recordControls
                    recordExtras
                    replayControls
                    captionsControls

                    Divider().frame(height: 22)

                    // Cluster 2 — go-live output
                    streamControls
                    virtualCameraControls
                    hdrToggle

                    Divider().frame(height: 22)

                    // Cluster 3 — tools
                    reactiveTriggerControl
                    autoDirectorButton
                    midiButton
                    controlServerToggle
                    broadcastCheckButton
                    SceneCollectionsMenu()
                }
            }

            helpButton
            onAirBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        // Push the persisted RTMP creds into the engine on launch and whenever
        // they change, so an obs-websocket StartStream (which carries no URL)
        // publishes to the current target instead of a stale/empty one (W10).
        .onAppear {
            streamKey = Self.loadPrimaryStreamKey()
            engine.configureStream(url: rtmpURL, streamKey: streamKey)
        }
        .onChange(of: rtmpURL) { engine.configureStream(url: rtmpURL, streamKey: streamKey) }
        .onChange(of: streamKey) {
            // Persist the secret to the Keychain (not UserDefaults) and push it into
            // the engine so an obs StartStream publishes to the current target.
            KeychainStore.set(streamKey, for: KeychainStore.primaryStreamKeyAccount)
            engine.configureStream(url: rtmpURL, streamKey: streamKey)
        }
    }

    /// Codex #8: load the primary stream key from the Keychain, migrating a legacy
    /// plaintext value left in `UserDefaults` by the old `@AppStorage` once.
    private static func loadPrimaryStreamKey() -> String {
        if let key = KeychainStore.get(KeychainStore.primaryStreamKeyAccount) { return key }
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: "stream.key"), !legacy.isEmpty {
            // Only delete the legacy plaintext if the Keychain accepted it, else
            // the key is lost under ad-hoc signing (re-verify #8).
            if KeychainStore.set(legacy, for: KeychainStore.primaryStreamKeyAccount) {
                defaults.removeObject(forKey: "stream.key")
            }
            return legacy
        }
        return ""
    }

    // MARK: Streaming (deliverable 3)

    private var streamControls: some View {
        HStack(spacing: 8) {
            Button {
                streamPopoverShown.toggle()
            } label: {
                Label(engine.isStreaming ? "Streaming" : "Stream",
                      systemImage: engine.isStreaming ? "dot.radiowaves.up.forward" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(engine.isStreaming ? .red : .primary)
            }
            .help("Stream the program live to YouTube, Twitch, or any RTMP/SRT platform. Click to set up your destination.")
            .popover(isPresented: $streamPopoverShown, arrowEdge: .bottom) { streamPopover }

            // Health glyphs while live (bitrate + dropped appends).
            if engine.isStreaming {
                HStack(spacing: 6) {
                    Text(engine.streamStateDescription)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Label(Self.bitrateString(engine.streamBitrate), systemImage: "gauge.with.dots.needle.bottom.50percent")
                        .font(.caption.monospacedDigit())
                    if engine.streamDroppedAppends > 0 {
                        Label("\(engine.streamDroppedAppends)", systemImage: "exclamationmark.triangle")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                            .help("Dropped appends")
                    }
                }
            }
        }
    }

    /// Whether Go Live has something to publish: a complete primary RTMP target
    /// OR at least one enabled restream destination (deliverable B).
    private var canGoLive: Bool {
        (!rtmpURL.isEmpty && !streamKey.isEmpty)
            || engine.destinations.contains(where: \.enabled)
    }

    private var streamPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stream").font(.headline)

            // Plain-language orientation so a first-timer knows exactly what to
            // paste and where it comes from (item 1 — the setup felt intimidating).
            Label {
                Text("Paste the RTMP URL and stream key from your platform's \u{201C}Stream\u{201D} settings.\nYouTube: rtmp://a.rtmp.youtube.com/live2 · Twitch: rtmp://live.twitch.tv/app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Text("Primary (RTMP)").font(.subheadline.weight(.semibold))
            TextField("RTMP URL (rtmp://…)", text: $rtmpURL)
                .textFieldStyle(.roundedBorder)
                .disabled(engine.isStreaming)
                .help("The server/ingest URL from your streaming platform, e.g. rtmp://a.rtmp.youtube.com/live2")
            SecureField("Stream key", text: $streamKey)
                .textFieldStyle(.roundedBorder)
                .disabled(engine.isStreaming)
                .help("The private stream key from your platform. Keep it secret — anyone with it can stream to your channel.")

            if engine.isStreaming {
                LabeledContent("State", value: engine.streamStateDescription)
                LabeledContent("Bitrate", value: Self.bitrateString(engine.streamBitrate))
                LabeledContent("Dropped", value: "\(engine.streamDroppedAppends)")
            }

            Divider()

            // Multi-destination restream editor (add/remove/enable RTMP + SRT).
            DestinationsEditor().environmentObject(engine)

            HStack {
                Spacer()
                if engine.isStreaming {
                    Button("Stop Streaming", role: .destructive) { engine.stopStream() }
                } else {
                    Button("Go Live") {
                        engine.goLive(rtmpURL: rtmpURL, streamKey: streamKey)
                        streamPopoverShown = false
                    }
                    .buttonStyle(.borderedProminent)
                    // Need a complete primary OR ≥1 enabled destination. An RTMP
                    // primary with an empty key is unpublishable (W9), so it does
                    // not count toward this on its own.
                    .disabled(!canGoLive)
                    // Explain WHY it's greyed out rather than leaving a dead end.
                    .help(canGoLive
                          ? "Start streaming to your configured target(s)"
                          : "Enter an RTMP URL and stream key above, or enable a destination below, to go live.")
                }
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    static func bitrateString(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
        }
        return String(format: "%d kbps", bitsPerSecond / 1000)
    }

    // MARK: Record

    private var recordControls: some View {
        HStack(spacing: 8) {
            Button {
                engine.toggleRecording()
            } label: {
                Label(engine.isRecording ? "Stop" : "Record",
                      systemImage: engine.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(engine.isRecording ? .red : .primary)
            }
            .help("Record the program to ~/Movies/Prism")

            if let started = engine.recordStartDate {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Self.elapsedString(from: started, to: context.date))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.red)
                }
            } else if engine.lastRecordingURL != nil {
                // Confirm success with a clear destination + a Reveal affordance
                // (item 4 — an action that succeeds should say so).
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Recording saved to ~/Movies/Prism")
                Button("Reveal") { engine.revealLastRecording() }
                    .controlSize(.small)
                    .help("Show the finished recording in ~/Movies/Prism in Finder")
            }
        }
    }

    static func elapsedString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    // MARK: ISO recording + Final Cut export (deliverables 3 & 4)

    private var recordExtras: some View {
        HStack(spacing: 8) {
            Button {
                isoPopoverShown.toggle()
            } label: {
                Label("ISO", systemImage: "square.stack.3d.up")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(engine.isoArmedSourceIDs.isEmpty ? Color.primary : .accentColor)
            }
            .help(engine.isoArmedSourceIDs.isEmpty
                  ? "ISO recording — save a separate clean file per camera/source, in sync with the program. Arm sources before you press Record."
                  : "ISO recording — \(engine.isoArmedSourceIDs.count) source\(engine.isoArmedSourceIDs.count == 1 ? "" : "s") armed. A clean per-source file will record alongside the program.")
            .popover(isPresented: $isoPopoverShown, arrowEdge: .bottom) { isoPopover }

            Button {
                engine.exportFinalCutProject()
            } label: {
                Label("Export to Final Cut Pro", systemImage: "film.stack")
                    .labelStyle(.iconOnly)
            }
            .disabled(!engine.lastMulticamExportable)
            .help(engine.lastMulticamExportable
                  ? "Export the last multi-angle session as a Final Cut Pro multicam project"
                  : "Disabled — record with at least one ISO angle armed (see the ISO button) to enable Final Cut Pro export.")
        }
    }

    private var isoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ISO Recording").font(.headline)
            Text("Record a clean per-source file alongside the program, all on one shared timeline. Arm before recording.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)

            let videoSources = engine.activeSources.filter(\.isVideo)
            if videoSources.isEmpty {
                Text("No video sources to record.").foregroundStyle(.secondary)
            } else {
                ForEach(videoSources, id: \.id) { active in
                    Toggle(isOn: Binding(get: { engine.isISOArmed(active.id) },
                                         set: { engine.setISOArmed($0, for: active.id) })) {
                        HStack {
                            Text(active.descriptor.name).lineLimit(1)
                            Spacer()
                            if let status = engine.isoStatuses[active.id] {
                                Text(status).font(.caption.monospacedDigit()).foregroundStyle(.red)
                            }
                        }
                    }
                    .disabled(engine.isRecording)
                }
            }
            // Multitrack AUDIO: arm per-source clean audio tracks recorded
            // beside the program on a shared timeline (deliverable 3).
            let audioSources = engine.activeSources.filter(\.isAudio)
            if !audioSources.isEmpty {
                Divider()
                Text("Multitrack Audio").font(.caption.bold())
                Text("Record each armed audio source as its own track for post mixing.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 320, alignment: .leading)
                ForEach(audioSources, id: \.id) { active in
                    Toggle(isOn: Binding(get: { engine.isMultitrackArmed(active.id) },
                                         set: { engine.setMultitrackArmed($0, for: active.id) })) {
                        Text(active.descriptor.name).lineLimit(1)
                    }
                    .disabled(engine.isRecording)
                }
            }

            if engine.isRecording {
                Text("Locked while recording.").font(.caption).foregroundStyle(.orange)
            }

            if !engine.lastISOFiles.isEmpty {
                Divider()
                Text("Last session files").font(.caption.bold())
                ForEach(engine.lastISOFiles.keys.sorted(by: { $0.raw < $1.raw }), id: \.self) { id in
                    if let url = engine.lastISOFiles[id] {
                        Label(url.lastPathComponent, systemImage: "doc.badge.arrow.up")
                            .font(.caption).lineLimit(1)
                    }
                }
            }

            if !engine.lastMultitrackFiles.isEmpty {
                Divider()
                Text("Last audio tracks").font(.caption.bold())
                ForEach(engine.lastMultitrackFiles.keys.sorted(by: { $0.raw < $1.raw }), id: \.self) { id in
                    if let url = engine.lastMultitrackFiles[id] {
                        Label(url.lastPathComponent, systemImage: "waveform")
                            .font(.caption).lineLimit(1)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: Replay buffer (deliverable 2)

    private var replayControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { engine.replayArmed },
                                 set: { engine.setReplayArmed($0) })) {
                Label("Replay", systemImage: "backward.circle")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("Instant replay — continuously buffer the last few seconds of program so you can save a replay clip at any moment.")

            if engine.replayArmed {
                Menu {
                    ForEach([15.0, 30.0, 60.0, 120.0], id: \.self) { secs in
                        Button {
                            engine.setReplayLength(secs)
                        } label: {
                            if engine.replayLengthSeconds == secs {
                                Label("\(Int(secs))s", systemImage: "checkmark")
                            } else {
                                Text("\(Int(secs))s")
                            }
                        }
                    }
                } label: {
                    Text("\(Int(engine.replayLengthSeconds))s · \(Int(engine.replayBufferedSeconds))s buffered")
                        .font(.caption.monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    engine.saveReplay()
                } label: {
                    Label("Save Replay", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .help("Save the buffered window (with program audio) to ~/Movies/Prism/Replays and reveal it")

                // "Clip that moment" (feature 3): saves just the last N seconds of
                // the same armed replay ring to ~/Movies/Prism/Clips and reveals it.
                Menu {
                    ForEach([10.0, 15.0, 20.0, 30.0], id: \.self) { secs in
                        Button {
                            engine.setClipLength(secs)
                        } label: {
                            if engine.clipLengthSeconds == secs {
                                Label("Last \(Int(secs))s", systemImage: "checkmark")
                            } else {
                                Text("Last \(Int(secs))s")
                            }
                        }
                    }
                } label: {
                    Label("Clip \(Int(engine.clipLengthSeconds))s", systemImage: "scissors")
                        .font(.caption)
                        .lineLimit(1)
                } primaryAction: {
                    engine.clipThatMoment()
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Clip that moment — save the last \(Int(engine.clipLengthSeconds))s of program to ~/Movies/Prism/Clips and reveal it. Use the menu to change the window.")
            } else if engine.lastReplayURL != nil {
                Button("Reveal Replay") { engine.revealLastReplay() }
                    .controlSize(.small)
                    .help("Show the last saved replay in Finder")
            }
        }
    }

    // MARK: Live captions (feature 1)

    private var captionsControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { engine.captionsEnabled },
                                 set: { engine.setCaptionsEnabled($0) })) {
                Label("Captions", systemImage: "captions.bubble")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("Live captions — transcribe the program audio on-device and composite a subtitle overlay over the program.")

            // Clear one-line note when the on-device captioner can't run (no
            // authorization / no on-device model). Never a crash — just disabled.
            if engine.captionsEnabled, let note = engine.captionsStatusNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(note)
            }
        }
    }

    // MARK: Reactive trigger (feature 4)

    private var reactiveTriggerControl: some View {
        Menu {
            ForEach(ReactiveTrigger.allCases) { action in
                Button {
                    engine.setReactiveTrigger(action)
                } label: {
                    if engine.reactiveTrigger == action {
                        Label(action.label, systemImage: "checkmark")
                    } else {
                        Text(action.label)
                    }
                }
            }
        } label: {
            Label("On loud hit", systemImage: engine.reactiveTrigger == .none
                  ? "bolt.slash" : "bolt.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(engine.reactiveTrigger == .none ? .primary : Color.accentColor)
        }
        .menuStyle(.button)
        .help("Reactive trigger — on a loud transient, fire a strobe/meme or arm a stinger for the next scene switch. Off by default.")
    }

    // MARK: Virtual camera

    private var virtualCameraControls: some View {
        HStack(spacing: 8) {
            // Toggle mirrors the REQUEST; on-air (vcamOutputEnabled) flips
            // only once the feeder confirms it is feeding (C30).
            Toggle(isOn: Binding(get: { engine.vcamOutputRequested },
                                 set: { engine.setVirtualCameraOutput($0) })) {
                Label("Virtual Camera", systemImage: "web.camera")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("Virtual Camera — send the Prism program into Zoom, Meet, or any app as a webcam.")

            Button {
                vcamPopoverShown.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .help("Virtual camera status & activate the system extension")
            .popover(isPresented: $vcamPopoverShown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Virtual Camera").font(.headline)
                    LabeledContent("Extension", value: engine.vcamInstallStatus)
                    LabeledContent("Output", value: engine.vcamFeederStatus)
                    Button(engine.vcamActivationInFlight ? "Activating…" : "Activate Extension") {
                        engine.activateVirtualCameraExtension()
                    }
                    .disabled(engine.vcamActivationInFlight)
                }
                .labeledContentStyle(.automatic)
                .frame(width: 420)
                .padding(16)
            }
        }
    }

    // MARK: Control server

    private var controlServerToggle: some View {
        Toggle(isOn: Binding(get: { engine.controlServerRunning },
                             set: { engine.setControlServer($0) })) {
            Label("Control server", systemImage: "network")
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .help("Remote control server (port 4455) — lets a Stream Deck or OBS-remote app control Prism. Compatible with the obs-websocket protocol.")
    }

    // MARK: Broadcast Check (deliverable 2)

    private var broadcastCheckButton: some View {
        Button {
            broadcastCheckShown = true
        } label: {
            Label("Broadcast Check", systemImage: broadcastCheckIcon)
                .labelStyle(.iconOnly)
                .foregroundStyle(broadcastCheckTint)
        }
        .help("Broadcast Check — run preflight checks (audio, disk space, network, sources) to catch problems before you go live.")
        .popover(isPresented: $broadcastCheckShown, arrowEdge: .bottom) {
            BroadcastCheckView().environmentObject(engine)
        }
    }

    private var broadcastCheckIcon: String {
        switch engine.lastBroadcastReport?.overall {
        case .fail: return "checklist.unchecked"
        case .warn: return "checklist"
        case .pass: return "checklist.checked"
        case nil: return "checklist"
        }
    }

    private var broadcastCheckTint: Color {
        switch engine.lastBroadcastReport?.overall {
        case .fail: return .red
        case .warn: return .orange
        case .pass: return .green
        case nil: return .primary
        }
    }

    // MARK: HDR output (Integration 4)

    private var hdrLocked: Bool {
        engine.isRecording || engine.isStreaming || engine.replayArmed || engine.vcamOutputEnabled
    }

    private var hdrToggle: some View {
        Toggle(isOn: Binding(get: { engine.hdrEnabled },
                             set: { engine.setHDREnabled($0) })) {
            Label("HDR", systemImage: "sun.max")
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .disabled(hdrLocked)
        // When locked, say WHY rather than leaving a mystery grey control (item 4).
        .help(hdrLocked
              ? "HDR is locked while on-air. Stop recording, streaming, replay, and the virtual camera to switch HDR on or off."
              : "HDR — run the program in high dynamic range (Rec.2020 HLG, 10-bit) and tag recordings as HDR. Needs an HDR display to preview correctly. Can only be changed while off-air.")
    }

    // MARK: Auto-Director (Integration 3)

    private var autoDirectorButton: some View {
        Button {
            directorPopoverShown.toggle()
        } label: {
            Label("Auto-Director", systemImage: "wand.and.stars")
                .labelStyle(.iconOnly)
                .foregroundStyle(engine.autoDirectorEnabled ? .green : .primary)
        }
        .help("Auto-Director — automatically cut the program to whichever source is most active and auto-frame it.")
        .popover(isPresented: $directorPopoverShown, arrowEdge: .bottom) {
            AutoDirectorPanel().environmentObject(engine)
        }
    }

    // MARK: MIDI control surface (Integration 1)

    private var midiButton: some View {
        Button {
            midiPopoverShown.toggle()
        } label: {
            Label("MIDI", systemImage: "pianokeys")
                .labelStyle(.iconOnly)
                .foregroundStyle(engine.controlSurfaceEnabled ? .green : .primary)
        }
        .help("MIDI control surface — map physical knobs, faders, and buttons on a MIDI controller to Prism actions.")
        .popover(isPresented: $midiPopoverShown, arrowEdge: .bottom) {
            MIDIControlPanel().environmentObject(engine)
        }
    }

    // MARK: Getting Started

    private var helpButton: some View {
        Button {
            showHelp = true
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .help("Getting Started — how to add sources, apply effects, and go live")
    }

    // MARK: On-air

    @ViewBuilder
    private var onAirBadge: some View {
        if engine.isOnAir {
            Label("ON AIR", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.red, in: Capsule())
                .foregroundStyle(.white)
        } else {
            Text("OFF AIR")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

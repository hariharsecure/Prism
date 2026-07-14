import PrismAudio
import PrismCore
import SwiftUI

/// Per-channel UI state. AppEngine exposes only the mixer *setters* (the mixer
/// itself is private), so the view is the source of truth for fader/mute/solo
/// positions — seeded to the engine defaults (unity gain, unmuted, unsoloed).
private struct ChannelUI {
    var gain: Double = 1.0
    var muted = false
    var solo = false
}

/// Bottom drawer (DESIGN §6): one channel strip per audio source plus a master
/// strip, a monitoring toggle, and "Add System Audio". Collapsible.
struct MixerDrawer: View {
    @EnvironmentObject private var engine: AppEngine
    @Binding var expanded: Bool
    /// When embedded in the tabbed BottomDrawer, the outer drawer owns the
    /// collapse chevron + the divider, so this view drops its own chevron and
    /// always shows content (the tab bar governs visibility).
    var embedded = false

    @State private var channels: [SourceID: ChannelUI] = [:]

    // Which channel strip's FX (inserts + voice-iso) popover is open.
    @State private var fxPopoverSource: SourceID?

    // Ducking rule draft (deliverable 4).
    @State private var duckTarget: SourceID?
    @State private var duckKey: SourceID?
    @State private var duckThreshold: Double = -30
    @State private var duckRatio: Double = 8

    private var audioSources: [ActiveSource] {
        engine.activeSources.filter(\.isAudio)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if embedded || expanded {
                if !embedded { Divider() }
                content
                if audioSources.count >= 2 {
                    Divider()
                    duckingBar
                }
            }
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !embedded {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Label("Mixer", systemImage: expanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse the audio mixer" : "Expand the audio mixer")
            }

            Text("\(audioSources.count) channel\(audioSources.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()

            Toggle(isOn: Binding(get: { engine.isAudioMonitoringEnabled },
                                 set: { engine.setAudioMonitoring($0) })) {
                Label("Monitor", systemImage: "headphones")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Route the master mix to your output device")

            Button {
                engine.addSystemAudio()
            } label: {
                Label("Add System Audio", systemImage: "speaker.wave.2.circle")
            }
            .controlSize(.small)
            .disabled(engine.isSystemAudioActive)
            .help(engine.isSystemAudioActive
                  ? "System audio is already captured"
                  : "Capture system-wide audio as a source (macOS 14.2+)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var content: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                if audioSources.isEmpty {
                    Text("No audio sources. Add a microphone or system audio.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(height: 150)
                        .padding(.horizontal, 8)
                }
                ForEach(audioSources, id: \.id) { source in
                    channelStrip(source)
                }
                if !audioSources.isEmpty {
                    Divider().frame(height: 150)
                    masterStrip
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 200)
        .onChange(of: engine.activeSources.map(\.id)) { syncChannels() }
        .onAppear(perform: syncChannels)
    }

    // MARK: Channel strip

    @ViewBuilder
    private func channelStrip(_ source: ActiveSource) -> some View {
        let id = source.id
        let ui = channels[id] ?? ChannelUI()
        VStack(spacing: 6) {
            Text(source.descriptor.name)
                .font(.caption2).lineLimit(1).frame(width: 78)

            HStack(spacing: 6) {
                // Real per-channel post-fader peak, published by AppEngine's
                // meter poll (falls back to 0 before the first sample).
                LevelMeter(level: engine.channelStates[id]?.peakLinear ?? 0)
                    .frame(height: 110)
                VerticalFader(value: Binding(
                    get: { channels[id]?.gain ?? 1.0 },
                    set: { newValue in
                        channels[id, default: ChannelUI()].gain = newValue
                        engine.setChannelGain(Float(newValue), for: id)
                    }), range: 0...1.5)
            }
            .frame(height: 114)

            HStack(spacing: 4) {
                Button("M") {
                    channels[id, default: ChannelUI()].muted.toggle()
                    engine.setChannelMuted(channels[id]?.muted ?? false, for: id)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(ui.muted ? .red : nil)
                .help(ui.muted ? "Unmute this channel" : "Mute this channel")

                Button("S") {
                    channels[id, default: ChannelUI()].solo.toggle()
                    engine.setChannelSolo(channels[id]?.solo ?? false, for: id)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(ui.solo ? .yellow : nil)
                .help(ui.solo ? "Unsolo — hear all channels" : "Solo — hear only this channel")
            }

            // AUv3 inserts + voice isolation (deliverable 2).
            HStack(spacing: 4) {
                let insertCount = engine.channelStates[id]?.insertCount ?? 0
                let voiceIso = engine.channelStates[id]?.voiceIsolationEnabled ?? false

                Button {
                    fxPopoverSource = id
                } label: {
                    Text(insertCount > 0 ? "FX \(insertCount)" : "FX")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(insertCount > 0 ? .accentColor : nil)
                .help("FX — add audio effects (EQ, compressor, reverb, noise gate…) to this channel.")
                .popover(isPresented: Binding(get: { fxPopoverSource == id },
                                              set: { if !$0 { fxPopoverSource = nil } }),
                         arrowEdge: .top) { fxPopover(id) }

                Button {
                    engine.setChannelVoiceIsolation(!voiceIso, for: id)
                } label: {
                    Image(systemName: "waveform.badge.mic")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(voiceIso ? .green : nil)
                .help(voiceIso ? "Voice isolation on" : "Isolate voice / remove noise")
            }
        }
        .frame(width: 86)
    }

    // MARK: FX inserts editor (deliverable 2)

    @ViewBuilder
    private func fxPopover(_ id: SourceID) -> some View {
        let inserts = engine.channelInserts[id] ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio Inserts").font(.headline)
            Text("Audio Unit (AUv3) effects, applied in order before the master mix.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 300, alignment: .leading)

            if inserts.isEmpty {
                Text("No inserts. Add an effect below.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(inserts.enumerated()), id: \.offset) { index, effect in
                    HStack(spacing: 6) {
                        Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(effect.name).font(.caption).lineLimit(1)
                            Text(effect.manufacturer).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { moveInsert(from: index, by: -1, in: id) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless).controlSize(.mini).disabled(index == 0)
                        .help("Move insert earlier in the chain")
                        Button { moveInsert(from: index, by: 1, in: id) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless).controlSize(.mini).disabled(index == inserts.count - 1)
                        .help("Move insert later in the chain")
                        Button { removeInsert(at: index, in: id) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless).controlSize(.mini).foregroundStyle(.secondary)
                        .help("Remove this insert")
                    }
                }
            }

            Divider()

            let catalog = engine.availableAudioEffects()
            Menu {
                if catalog.isEmpty {
                    Text("No Audio Units installed")
                } else {
                    ForEach(Array(catalog.enumerated()), id: \.offset) { _, effect in
                        Button("\(effect.name) — \(effect.manufacturer)") { addInsert(effect, to: id) }
                    }
                }
            } label: {
                Label("Add effect", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(catalog.isEmpty)

            Toggle(isOn: Binding(get: { engine.channelStates[id]?.voiceIsolationEnabled ?? false },
                                 set: { engine.setChannelVoiceIsolation($0, for: id) })) {
                Label("Voice isolation", systemImage: "waveform.badge.mic")
            }
            .controlSize(.small)
            .help("Strip low rumble + high hiss to isolate the voice band")
        }
        .padding(14)
        .frame(width: 340)
    }

    private func addInsert(_ effect: MixerChannel.AudioEffectComponent, to id: SourceID) {
        var list = engine.channelInserts[id] ?? []
        list.append(effect)
        engine.setChannelInserts(list, for: id)
    }

    private func removeInsert(at index: Int, in id: SourceID) {
        var list = engine.channelInserts[id] ?? []
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        engine.setChannelInserts(list, for: id)
    }

    private func moveInsert(from index: Int, by delta: Int, in id: SourceID) {
        var list = engine.channelInserts[id] ?? []
        let target = index + delta
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        engine.setChannelInserts(list, for: id)
    }

    // MARK: Master strip

    private var masterStrip: some View {
        let loud = engine.masterLoudness
        return VStack(spacing: 6) {
            Text("Master").font(.caption2.weight(.semibold)).frame(width: 78)
            HStack(spacing: 6) {
                LevelMeter(level: engine.mixerMasterLevel)
                    .frame(height: 110)
                LevelMeter(level: engine.mixerMasterLevel)
                    .frame(height: 110)
            }
            .frame(height: 114)
            // Broadcast loudness (EBU R128): momentary / short-term / integrated
            // LUFS + true-peak dBTP, polled from the LoudnessMeter (deliverable 3).
            Text("M \(fmtLUFS(loud.momentary))  S \(fmtLUFS(loud.shortTerm))  I \(fmtLUFS(loud.integrated)) LUFS")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Loudness in LUFS (broadcast standard EBU R128): M = momentary, S = short-term, I = integrated over the whole session. Most platforms target about −14 LUFS integrated.")
            Text("TP \(fmtLUFS(loud.truePeak)) dBTP")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .help("True peak in dBTP — the loudest instantaneous level. Keep it under −1 dBTP to avoid clipping/distortion.")
        }
        .frame(width: 150)
    }

    /// One LUFS/dBTP field: one decimal, or an em-dash when there is no
    /// qualifying audio yet (`-.infinity`).
    private func fmtLUFS(_ v: Double) -> String {
        v.isFinite ? String(format: "%.1f", v) : "–"
    }

    // MARK: Ducking (deliverable 4)

    private var duckingBar: some View {
        HStack(spacing: 8) {
            Text("Ducking").font(.caption.weight(.semibold))

            Picker("Duck", selection: $duckTarget) {
                Text("target…").tag(SourceID?.none)
                ForEach(audioSources, id: \.id) { s in
                    Text(s.descriptor.name).tag(SourceID?.some(s.id))
                }
            }
            .labelsHidden().frame(width: 120)

            Text("when").font(.caption).foregroundStyle(.secondary)

            Picker("Key", selection: $duckKey) {
                Text("key…").tag(SourceID?.none)
                ForEach(audioSources, id: \.id) { s in
                    Text(s.descriptor.name).tag(SourceID?.some(s.id))
                }
            }
            .labelsHidden().frame(width: 120)
            Text("is loud").font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 3) {
                Text("Thr").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $duckThreshold, in: -60...0).frame(width: 70)
                Text("\(Int(duckThreshold)) dB").font(.caption2.monospacedDigit()).frame(width: 42)
            }
            HStack(spacing: 3) {
                Text("Ratio").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $duckRatio, in: 1...20).frame(width: 60)
                Text(String(format: "%.0f:1", duckRatio)).font(.caption2.monospacedDigit()).frame(width: 34)
            }

            Button("Apply") { applyDucking() }
                .controlSize(.small)
                .disabled(duckTarget == nil || duckKey == nil || duckTarget == duckKey)
            Button("Clear") { if let t = duckTarget { engine.clearDucking(target: t) } }
                .controlSize(.small)
                .disabled(duckTarget == nil)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func applyDucking() {
        guard let target = duckTarget, let key = duckKey else { return }
        engine.setDucking(target: target, key: key,
                          config: DuckingConfig(thresholdDB: duckThreshold, ratio: duckRatio))
    }

    // MARK: State

    /// Drop UI state for channels whose source went away (keep existing ones).
    private func syncChannels() {
        let live = Set(audioSources.map(\.id))
        channels = channels.filter { live.contains($0.key) }
        for id in live where channels[id] == nil { channels[id] = ChannelUI() }
        // Drop ducking selections whose source went away (Codex #3), else Apply
        // would send a dead SourceID to setDucking.
        if let t = duckTarget, !live.contains(t) { duckTarget = nil }
        if let k = duckKey, !live.contains(k) { duckKey = nil }
    }
}

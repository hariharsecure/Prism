import PrismSound
import SwiftUI

/// Sound tab (APP_UI_DESIGN §1): a soundboard PAD GRID, a compact 16-step beat
/// maker, and a music-bed player. Everything triggers into the program mix (its
/// own mixer channels), so the master meter in the Mixer tab moves on trigger.
///
/// Layout rules: the whole board is inside a vertical `ScrollView` so nothing
/// overflows the drawer; the pad grid uses an adaptive `LazyVGrid` (pads wrap);
/// the 16-step rows scroll horizontally; every label is `.lineLimit(1)`.
struct SoundBoardView: View {
    @EnvironmentObject private var engine: AppEngine

    /// Which pad is being assigned (drives the browser sheet).
    @State private var assigningPad: PadTarget?
    struct PadTarget: Identifiable { let id: Int }

    private let padColumns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if !engine.soundLibraryLoaded {
                    Label("No sound library installed — pads use whatever you assign; synth music beds still play.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                padSection
                Divider()
                beatSection
                Divider()
                bedSection
            }
            .padding(12)
        }
        .frame(height: 240)
        .onAppear { engine.prepareSound() }
        .sheet(item: $assigningPad) { target in
            SoundBrowserSheet(padIndex: target.id, assigning: $assigningPad)
                .environmentObject(engine)
        }
    }

    // MARK: Pads

    private var padSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Soundboard").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: padColumns, alignment: .leading, spacing: 8) {
                ForEach(0..<16, id: \.self) { i in pad(i) }
            }
        }
    }

    @ViewBuilder
    private func pad(_ index: Int) -> some View {
        let id = engine.padAssignments[index]
        Button {
            if let id { engine.triggerSound(id: id) } else { assigningPad = PadTarget(id: index) }
        } label: {
            VStack(spacing: 2) {
                if let id {
                    Text(engine.soundName(forID: id)).font(.caption2.weight(.semibold)).lineLimit(1)
                    Text(engine.soundCategory(forID: id) ?? "").font(.system(size: 9))
                        .foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Image(systemName: "plus").font(.caption)
                    Text("Assign").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 6)
            .background(id != nil ? Color.accentColor.opacity(0.16) : Color.gray.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(id.map { "Trigger \(engine.soundName(forID: $0))" } ?? "Assign a sound to this pad")
        .contextMenu {
            Button("Reassign…") { assigningPad = PadTarget(id: index) }
            if engine.padAssignments[index] != nil {
                Button("Clear", role: .destructive) { engine.clearPad(index) }
            }
        }
    }

    // MARK: Beat maker

    private var beatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Beat Maker").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Button {
                    engine.beatIsPlaying ? engine.stopBeats() : engine.playBeats()
                } label: {
                    Label(engine.beatIsPlaying ? "Stop" : "Play",
                          systemImage: engine.beatIsPlaying ? "stop.fill" : "play.fill")
                }
                .controlSize(.small)

                HStack(spacing: 4) {
                    Text("BPM").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { engine.beatPattern.bpm },
                                          set: { engine.setBPM($0) }), in: 60...200)
                        .frame(width: 90)
                    Text("\(Int(engine.beatPattern.bpm))").font(.caption2.monospacedDigit()).frame(width: 26)
                }
                HStack(spacing: 4) {
                    Text("Swing").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { engine.beatPattern.swing },
                                          set: { engine.setSwing($0) }), in: 0...0.6)
                        .frame(width: 70)
                }
                Spacer()
            }

            // 16-step rows scroll horizontally so they never overflow the drawer.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(engine.beatPattern.tracks.enumerated()), id: \.offset) { t, track in
                        HStack(spacing: 3) {
                            Text(track.name).font(.system(size: 9)).lineLimit(1)
                                .frame(width: 44, alignment: .leading)
                            ForEach(0..<track.steps.count, id: \.self) { s in
                                Button {
                                    engine.toggleBeatStep(track: t, step: s)
                                } label: {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(track.steps[s].on ? Color.accentColor
                                              : Color.gray.opacity(s % 4 == 0 ? 0.28 : 0.15))
                                        .frame(width: 18, height: 18)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Music bed

    private var bedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Music Bed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Picker("Bed", selection: bedSelection) {
                    Text("Choose a bed…").tag(String?.none)
                    ForEach(engine.musicBeds) { bed in
                        Text(bed.name).tag(String?.some(bed.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)

                Button {
                    engine.bedIsPlaying ? engine.stopBed() : play()
                } label: {
                    Label(engine.bedIsPlaying ? "Stop" : "Play",
                          systemImage: engine.bedIsPlaying ? "stop.fill" : "play.fill")
                }
                .controlSize(.small)
                .disabled(!engine.bedIsPlaying && engine.activeBedID == nil && engine.musicBeds.isEmpty)

                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { engine.bedVolume },
                                          set: { engine.setBedVolume($0) }), in: 0...1)
                        .frame(width: 90)
                }

                Toggle(isOn: Binding(get: { engine.bedDuckingEnabled },
                                     set: { engine.setBedDucking($0) })) {
                    Label("Duck under mic", systemImage: "waveform.badge.mic")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Automatically lower the music when a microphone is speaking")

                Spacer()
            }
        }
    }

    private var bedSelection: Binding<String?> {
        Binding(get: { engine.activeBedID ?? engine.musicBeds.first?.id },
                set: { if let id = $0 { engine.playBed(id: id) } })
    }

    private func play() {
        let id = engine.activeBedID ?? engine.musicBeds.first?.id
        if let id { engine.playBed(id: id) }
    }
}

// MARK: - Sound browser (assign a pad)

/// Searchable category browser used to assign a sound to a soundboard pad.
struct SoundBrowserSheet: View {
    @EnvironmentObject private var engine: AppEngine
    let padIndex: Int
    @Binding var assigning: SoundBoardView.PadTarget?

    @State private var query = ""
    @State private var category: String?

    private var results: [SoundEntry] {
        let base = category.map { engine.sounds(inCategory: $0) } ?? engine.searchSounds(query)
        guard category != nil, !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign Sound to Pad \(padIndex + 1)").font(.headline)

            HStack(spacing: 8) {
                TextField("Search sounds…", text: $query).textFieldStyle(.roundedBorder)
                Picker("Category", selection: $category) {
                    Text("All").tag(String?.none)
                    ForEach(engine.soundCategories, id: \.self) { c in
                        Text(c).tag(String?.some(c))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            if results.isEmpty {
                Text(engine.soundLibraryLoaded ? "No matching sounds."
                     : "No sound library is installed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(results, id: \.id) { entry in
                    Button {
                        engine.assignSoundToPad(padIndex, id: entry.id)
                        assigning = nil
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.name).lineLimit(1)
                                Text(entry.category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 220)
            }

            HStack {
                Spacer()
                Button("Cancel") { assigning = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460, height: 380)
    }
}


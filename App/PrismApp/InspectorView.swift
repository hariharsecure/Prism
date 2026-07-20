import PrismColor
import PrismCompositor
import PrismCore
import PrismSources
import PrismVision
import SwiftUI
import UniformTypeIdentifiers
import simd

/// Right-rail Inspector (DESIGN §6): context-sensitive to the selected source.
/// Shows the per-source color grade + LUT + background effect, all bound
/// through the AppEngine effect setters. Empty state when nothing is selected.
struct InspectorView: View {
    @EnvironmentObject private var engine: AppEngine
    @EnvironmentObject private var selection: SelectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // Title the panel with the SELECTED layer's name so it's obvious
                // these effects belong to that layer (not the whole scene).
                if let id = selection.selectedSourceID, engine.sourceEffects[id] != nil {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Effects").font(.headline)
                        Text(engine.displayName(for: id))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Inspector").font(.headline)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let id = selection.selectedSourceID, engine.sourceEffects[id] != nil {
                // Fresh @State per source: keying by id re-inits the draft grade.
                SourceInspector(sourceID: id)
                    .id(id)
            } else {
                emptyState
            }
        }
    }

    /// Instructive empty state: teaches the operator what the Inspector does and
    /// exactly what to click, adapting to whether the scene has any layers yet.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyIcon)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(emptyBody)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
    }

    private var hasLayers: Bool { !engine.scene.layers.isEmpty }

    private var emptyIcon: String {
        if selection.selectedSourceID != nil { return "slider.horizontal.3" }
        return hasLayers ? "hand.tap" : "plus.rectangle.on.rectangle"
    }

    private var emptyTitle: String {
        if selection.selectedSourceID != nil { return "No adjustable effects" }
        return hasLayers ? "Select a layer" : "Add a source to begin"
    }

    private var emptyBody: String {
        if selection.selectedSourceID != nil {
            return "This source has no adjustable effects."
        }
        return hasLayers
            ? "Click a layer in the list above to grade its color, key out a green or dark background, or remove the background."
            : "Add a source from the left rail — click ＋ Add Source, or a camera under Cameras — to build your scene."
    }
}

/// The effects editor for one specific video source. Holds a local `draft`
/// grade so sliders stay responsive; commits are debounced into the engine.
private struct SourceInspector: View {
    @EnvironmentObject private var engine: AppEngine
    let sourceID: SourceID

    @State private var draft = ColorGrade.identity
    @State private var backgroundKind: BackgroundKind = .none
    @State private var blurRadius: Double = 12
    @State private var replaceColor = Color.green
    @State private var lutName: String?
    @State private var lutImporterShown = false

    // Chroma key (green/blue screen). Alternative keying path to background-remove.
    @State private var chromaEnabled = false
    @State private var chromaColor = Color.green
    @State private var chromaSimilarity = 0.4
    @State private var chromaSmoothness = 0.1
    @State private var chromaSpill = 1.0

    // Luma key (bright/dark backdrop). Alternative keying path to chroma/remove.
    @State private var lumaEnabled = false
    @State private var lumaLow = 0.75
    @State private var lumaHigh = 1.01
    @State private var lumaSmoothness = 0.08
    @State private var lumaInvert = false

    // Matte view — renders whichever keyer is active (chroma OR luma) as its
    // black-and-white matte so the operator can tune the key edges.
    @State private var matteView = false

    // Tiles / Grid (Build A) — animated grid of transparent holes revealing below.
    @State private var tileEnabled = false
    @State private var tileMode: TileGridMode = .flicker
    @State private var tileRows = 6
    @State private var tileCols = 8
    @State private var tileSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
    @State private var tileSoftness = 0.15
    @State private var tileSpeed = 1.0
    @State private var tileDirection: FXDirection = .left
    // Tile beat-sync (BEAT_SYNC_DESIGN) — drive the mask phase from the beat clock.
    @State private var tileSyncToBeat = false
    @State private var tileFlipsPerBeat = 1.0

    // Video wall (Build C) — tile this source into an N×M grid (kaleidoscope).
    @State private var wallEnabled = false
    @State private var wallRows = 2
    @State private var wallCols = 2
    @State private var wallMirror = false

    // Beat pulse (BEAT_SYNC_DESIGN) — scale/shake this layer on the beat.
    @State private var pulseEnabled = false
    @State private var pulseIntensity = 0.6
    @State private var pulseStyle: BeatPulseStyle = .bump

    // Montage (Build B) — live-reconfigurable auto-cycling reel.
    @State private var montageInterval = 2.5
    @State private var montageTransition: AppEngine.MontageTransitionKind = .crossfade
    @State private var montageCrossfade = 0.4
    @State private var montageKenBurns = true
    @State private var montageShuffle = false
    // Montage beat-sync (BEAT_SYNC_DESIGN) — cut on the downbeat.
    @State private var montageCutOnBeat = false
    @State private var montageCutEvery = 1

    // Presenter cutout (PresenterCutoutSource) — remove background on camera/movie.
    @State private var cutoutEnabled = false
    @State private var cutoutFeather = 3.0
    @State private var cutoutSolid = false
    @State private var cutoutColor = Color.green

    // Motion-graphics overlay (lower-third / name-tag / countdown / subscribe-bug).
    @State private var overlayName = "Name"
    @State private var overlaySubtitle = "Title"
    @State private var overlayCTA = "SUBSCRIBE"
    @State private var overlayCorner: MGCorner = .bottomLeft
    @State private var overlayAccent = Color(.sRGB, red: 0.15, green: 0.55, blue: 0.95)
    @State private var overlayIn = 0.5
    @State private var overlayHold = 3.0
    @State private var overlayOut = 0.5
    @State private var overlayCountdown = 10

    // Animated logo (entrance/idle/exit + corner + size). Live edits rebuild it.
    @State private var logoConfig = LogoConfig()

    // News-crawl ticker (text is live; speed/position/accent rebuild it).
    @State private var tickerText = ""
    @State private var tickerSpeed = 160.0
    @State private var tickerPosition: TickerPosition = .bottom
    @State private var tickerAccent = Color(.sRGB, red: 0.90, green: 0.16, blue: 0.20)

    // Credits roll (speed + loop).
    @State private var creditsSpeed = 90.0
    @State private var creditsLoop = false

    // Text reveal (None / typewriter / word-by-word / bounce-in) + duration.
    @State private var textRevealStyle: TextRevealStyle?
    @State private var textRevealDuration = 1.2

    // Character lip-sync + auto-blink.
    @State private var lipSyncEnabled = false
    @State private var autoBlinkEnabled = true

    // Per-layer motion (None / Glide / Orbit / Bounce / Float + speed).
    @State private var motionKind: LayerMotionKind = .none
    @State private var motionSpeed = 1.0

    // Strobe / flash — full-frame color flash on the beat (or a free-run timer).
    @State private var strobeEnabled = false
    @State private var strobeIntensity = 0.8
    @State private var strobeColor = Color.white
    @State private var strobeSyncToBeat = true
    @State private var strobeRate = 3.0

    private let gradeDebouncer = Debouncer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // (Source name shown in the panel header now — no duplicate here.)
                if engine.isCharacterSource(sourceID) {
                    characterSection
                    Divider()
                }
                if engine.isMovieSource(sourceID) {
                    videoSection
                    Divider()
                }
                if engine.isMontageSource(sourceID) {
                    montageSection
                    Divider()
                }
                if engine.isOverlaySource(sourceID) {
                    overlaySection
                    Divider()
                }
                if engine.isLogoSource(sourceID) {
                    logoSection
                    Divider()
                }
                if engine.isTickerSource(sourceID) {
                    tickerSection
                    Divider()
                }
                if engine.isCreditsSource(sourceID) {
                    creditsSection
                    Divider()
                }
                if engine.isTextSource(sourceID) {
                    textSection
                    Divider()
                }
                if engine.isCutoutCapable(sourceID) {
                    cutoutSection
                    Divider()
                }
                colorSection
                Divider()
                backgroundSection
                Divider()
                chromaSection
                Divider()
                lumaSection
                matteRow
                Divider()
                tileSection
                Divider()
                videoWallSection
                Divider()
                beatPulseSection
                Divider()
                strobeSection
                Divider()
                motionSection
            }
            .padding(12)
        }
        .onAppear(perform: loadFromEngine)
        // Auto-color resolves asynchronously on the capture thread and lands in
        // sourceEffects; adopt the new grade into the draft when it arrives.
        .onReceive(engine.$sourceEffects) { effects in
            guard let fx = effects[sourceID] else { return }
            if fx.grade != draft { draft = fx.grade }
        }
    }

    // MARK: Character (expression picker + reaction)

    private var characterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Character", systemImage: "person.crop.square.badge.video")
            HStack(spacing: 8) {
                // Menu picker (never segmented) — expression list can be any width.
                Picker("Expression", selection: Binding(
                    get: { engine.currentCharacterExpression(for: sourceID) ?? "" },
                    set: { engine.setCharacterExpression($0, for: sourceID) })) {
                    ForEach(engine.characterExpressions(for: sourceID), id: \.self) { name in
                        Text(name.capitalized).tag(name)
                    }
                }
                .accessibilityIdentifier("inspector.character.expression.picker")
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                Button {
                    engine.triggerCharacterReaction(for: sourceID)
                } label: {
                    Label("React", systemImage: "sparkles")
                }
                .accessibilityIdentifier("inspector.character.react")
                .controlSize(.small)
                .help("Play a quick impact-pop reaction")
                Spacer()
            }

            Toggle("Lip-sync to program audio", isOn: $lipSyncEnabled)
                .accessibilityIdentifier("inspector.character.lipSync.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: lipSyncEnabled) { engine.setCharacterLipSync(lipSyncEnabled, for: sourceID) }
                .help("Drive the mouth from the live program loudness. No audio → the mouth follows the expression.")
            Toggle("Auto-blink", isOn: $autoBlinkEnabled)
                .accessibilityIdentifier("inspector.character.autoBlink.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: autoBlinkEnabled) { engine.setCharacterAutoBlink(autoBlinkEnabled, for: sourceID) }

            Text("Swap the character's expression, play a reaction accent, or lip-sync the mouth to program audio.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Video (file source: loop toggle + native size)

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Video", systemImage: "film")
            Toggle(isOn: Binding(
                get: { engine.movieLoops(sourceID) },
                set: { engine.setMovieLoop($0, for: sourceID) })) {
                Text("Loop")
            }
            .accessibilityIdentifier("inspector.video.loop.toggle")
            .toggleStyle(.switch)
            .controlSize(.small)
            if let size = engine.movieNativeSize(for: sourceID) {
                Text("\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px"
                     + (engine.movieHasAudio(sourceID) ? " · has audio" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("Plays the clip on a loop; any soundtrack joins the mixer.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Color

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Color", systemImage: "camera.filters")

            gradeSlider("Exposure", value: $draft.exposure, in: -3...3, identity: 0)
            gradeSlider("Contrast", value: $draft.contrast, in: 0...2, identity: 1)
            gradeSlider("Saturation", value: $draft.saturation, in: 0...2, identity: 1)
            gradeSlider("Temperature", value: $draft.temperature, in: -1...1, identity: 0)
            gradeSlider("Tint", value: $draft.tint, in: -1...1, identity: 0)

            tripleGroup("Lift", plain: "Shadows", triple: $draft.lift, in: -0.5...0.5)
            tripleGroup("Gamma", plain: "Midtones", triple: $draft.gamma, in: 0.2...3)
            tripleGroup("Gain", plain: "Highlights", triple: $draft.gain, in: 0...2)

            HStack {
                Button {
                    engine.loadAutoColor(for: sourceID)
                } label: {
                    Label("Auto Color", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("inspector.color.auto")
                .controlSize(.small)
                .help("Analyze the next frame and apply a suggested grade")

                Button("Reset") {
                    draft = .identity
                    commitGrade(immediate: true)
                }
                .accessibilityIdentifier("inspector.color.reset")
                .controlSize(.small)
            }

            lutRow
        }
    }

    private var lutRow: some View {
        HStack(spacing: 6) {
            Button {
                lutImporterShown = true
            } label: {
                Label(lutName ?? "Load LUT…", systemImage: "square.stack.3d.forward.dottedline")
                    .lineLimit(1)
            }
            .accessibilityIdentifier("inspector.color.lut.load")
            .controlSize(.small)

            if lutName != nil {
                Button {
                    lutName = nil
                    engine.setLUT(url: nil, for: sourceID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityIdentifier("inspector.color.lut.clear")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear LUT")
            }
        }
        .fileImporter(isPresented: $lutImporterShown,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                let adopted = engine.setLUT(url: url, for: sourceID)
                if scoped { url.stopAccessingSecurityScopedResource() }
                // Only reflect the LUT name if the engine actually adopted it
                // (W11) — a parse failure surfaces via engine.lastError and the
                // UI keeps its previous LUT state instead of falsely showing one.
                // Label from the engine's adopted LUT (its .cube TITLE, else the
                // file name) so the import path and loadFromEngine agree — no
                // drift on reselect (Codex #4).
                if adopted {
                    lutName = engine.sourceEffects[sourceID]?.lut?.title ?? url.lastPathComponent
                }
            }
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Background", systemImage: "person.crop.rectangle")

            // A menu, not a segmented control: the right rail (min 240 pt) is too
            // narrow to hold four text segments ("Replace" clips off the edge) —
            // the same failure the scene Layout picker had. A menu fits any width.
            Picker("", selection: $backgroundKind) {
                ForEach(BackgroundKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .accessibilityIdentifier("inspector.background.kind.picker")
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: backgroundKind) { commitBackground() }

            switch backgroundKind {
            case .none:
                Text("Source shown as captured.")
                    .font(.caption).foregroundStyle(.secondary)
            case .remove:
                Text("Alpha-out the background (transparent).")
                    .font(.caption).foregroundStyle(.secondary)
            case .blur:
                labeledSlider("Radius", id: "inspector.background.radius.slider",
                              value: $blurRadius, in: 1...63,
                              format: { "\(Int($0)) px" }) { commitBackground() }
            case .replace:
                ColorPicker("Replace color", selection: $replaceColor, supportsOpacity: false)
                    .accessibilityIdentifier("inspector.background.replaceColor.picker")
                    .onChange(of: replaceColor) { commitBackground() }
            }
        }
    }

    // MARK: Chroma key

    private var chromaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Chroma Key", systemImage: "eyedropper.halffull")

            Toggle("Enable green/blue-screen key", isOn: $chromaEnabled)
                .accessibilityIdentifier("inspector.chroma.enable.toggle")
                .font(.caption)
                .controlSize(.small)
                .onChange(of: chromaEnabled) { commitChroma() }

            if chromaEnabled {
                HStack(spacing: 8) {
                    ColorPicker("Key color", selection: $chromaColor, supportsOpacity: false)
                        .accessibilityIdentifier("inspector.chroma.color.picker")
                        .onChange(of: chromaColor) { commitChroma() }
                    Spacer()
                    Button("Green") { applyChromaPreset(.greenScreen) }
                        .accessibilityIdentifier("inspector.chroma.preset.green")
                        .controlSize(.small)
                    Button("Blue") { applyChromaPreset(.blueScreen) }
                        .accessibilityIdentifier("inspector.chroma.preset.blue")
                        .controlSize(.small)
                }
                labeledSlider("Similarity", id: "inspector.chroma.similarity.slider",
                              value: $chromaSimilarity, in: 0...1,
                              format: { String(format: "%.2f", $0) }) { commitChroma() }
                labeledSlider("Smoothness", id: "inspector.chroma.smoothness.slider",
                              value: $chromaSmoothness, in: 0...0.3,
                              format: { String(format: "%.2f", $0) }) { commitChroma() }
                labeledSlider("Spill removal", id: "inspector.chroma.spill.slider",
                              value: $chromaSpill, in: 0...1,
                              format: { String(format: "%.2f", $0) }) { commitChroma() }
                Text("Keys out the backdrop (transparent) — an alternative to Background → Remove.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Remove a green/blue backdrop, keeping the foreground.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Luma key

    private var lumaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Luma Key", systemImage: "circle.lefthalf.filled")

            Toggle("Enable luminance key", isOn: $lumaEnabled)
                .accessibilityIdentifier("inspector.luma.enable.toggle")
                .font(.caption)
                .controlSize(.small)
                .onChange(of: lumaEnabled) { commitLuma() }

            if lumaEnabled {
                HStack(spacing: 8) {
                    Button("Bright bg") { applyLumaPreset(.brightBackground) }
                        .accessibilityIdentifier("inspector.luma.preset.bright")
                        .controlSize(.small)
                    Button("Dark bg") { applyLumaPreset(.darkBackground) }
                        .accessibilityIdentifier("inspector.luma.preset.dark")
                        .controlSize(.small)
                    Spacer()
                }
                labeledSlider("Low luma", id: "inspector.luma.low.slider",
                              value: $lumaLow, in: -0.01...1.01,
                              format: { String(format: "%.2f", $0) }) { commitLuma() }
                labeledSlider("High luma", id: "inspector.luma.high.slider",
                              value: $lumaHigh, in: -0.01...1.01,
                              format: { String(format: "%.2f", $0) }) { commitLuma() }
                labeledSlider("Smoothness", id: "inspector.luma.smoothness.slider",
                              value: $lumaSmoothness, in: 0...0.3,
                              format: { String(format: "%.2f", $0) }) { commitLuma() }
                Toggle("Invert (keep the band, key outside it)", isOn: $lumaInvert)
                    .accessibilityIdentifier("inspector.luma.invert.toggle")
                    .font(.caption)
                    .controlSize(.small)
                    .onChange(of: lumaInvert) { commitLuma() }
                Text("Keys out a bright or dark backdrop by brightness — an alternative to Chroma Key.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Remove a white/black backdrop by luminance, keeping the foreground.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Matte view (tune any active keyer)

    @ViewBuilder
    private var matteRow: some View {
        if chromaEnabled || lumaEnabled {
            Divider()
            Toggle(isOn: $matteView) {
                Label("View matte", systemImage: "square.on.square.dashed")
            }
            .accessibilityIdentifier("inspector.matte.toggle")
            .font(.caption)
            .controlSize(.small)
            .onChange(of: matteView) { engine.setMatteView(matteView, for: sourceID) }
            Text("Show the key's black-and-white matte to tune the edges; turn off to see the keyed image.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Montage (Build B: auto-cycling reel — live reconfigure)

    private var montageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Montage", systemImage: "rectangle.stack.badge.play")
            Text("\(engine.montageItemCount(for: sourceID)) items")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            labeledSlider("Interval", id: "inspector.montage.interval.slider",
                          value: $montageInterval, in: 0.3...10,
                          format: { String(format: "%.1f s", $0) }) {
                engine.reconfigureMontage(for: sourceID, interval: montageInterval)
            }
            HStack(spacing: 8) {
                Text("Transition").font(.caption)
                Picker("", selection: $montageTransition) {
                    ForEach(AppEngine.MontageTransitionKind.allCases) { k in Text(k.label).tag(k) }
                }
                .accessibilityIdentifier("inspector.montage.transition.picker")
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .onChange(of: montageTransition) { commitMontageTransition() }
                Spacer()
            }
            if montageTransition == .crossfade {
                labeledSlider("Fade", id: "inspector.montage.fade.slider",
                              value: $montageCrossfade, in: 0.1...2,
                              format: { String(format: "%.1f s", $0) }) { commitMontageTransition() }
            }
            Toggle("Ken Burns pan/zoom", isOn: $montageKenBurns)
                .accessibilityIdentifier("inspector.montage.kenBurns.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: montageKenBurns) {
                    engine.reconfigureMontage(for: sourceID, kenBurns: montageKenBurns)
                }
            Toggle("Shuffle order", isOn: $montageShuffle)
                .accessibilityIdentifier("inspector.montage.shuffle.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: montageShuffle) {
                    engine.reconfigureMontage(for: sourceID, shuffle: montageShuffle)
                }
            Toggle("Cut on beat", isOn: $montageCutOnBeat)
                .accessibilityIdentifier("inspector.montage.cutOnBeat.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: montageCutOnBeat) {
                    engine.setMontageCutOnBeat(montageCutOnBeat, for: sourceID)
                }
            if montageCutOnBeat {
                Stepper(value: $montageCutEvery, in: 1...16) {
                    Text("Cut every \(montageCutEvery) beat\(montageCutEvery == 1 ? "" : "s")")
                        .font(.caption).lineLimit(1)
                }
                .accessibilityIdentifier("inspector.montage.cutEvery.stepper")
                .controlSize(.small)
                .onChange(of: montageCutEvery) {
                    engine.setMontageCutEveryBeats(montageCutEvery, for: sourceID)
                }
                Text("Cuts land on the downbeat while the beat maker plays; the Interval still runs when stopped.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Auto-cycles the picked images/clips as one live source.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func commitMontageTransition() {
        let t: MontageSource.Transition = montageTransition == .cut
            ? .cut : .crossfade(duration: montageCrossfade)
        engine.reconfigureMontage(for: sourceID, transition: t)
    }

    // MARK: Tiles / Grid (Build A: animated holes reveal the layer beneath)

    private var tileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Tiles / Grid", systemImage: "square.grid.3x3")
            Toggle("Enable tile grid", isOn: $tileEnabled)
                .accessibilityIdentifier("inspector.tile.enable.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: tileEnabled) { commitTile() }

            if tileEnabled {
                HStack(spacing: 8) {
                    Text("Mode").font(.caption)
                    // Menu picker (never segmented) — labels are wide.
                    Picker("", selection: $tileMode) {
                        ForEach(TileGridMode.allCases) { m in Text(m.label).tag(m) }
                    }
                    .accessibilityIdentifier("inspector.tile.mode.picker")
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                    .onChange(of: tileMode) { commitTile() }
                    Spacer()
                }
                if tileMode == .gridWipe {
                    HStack(spacing: 8) {
                        Text("Direction").font(.caption)
                        Picker("", selection: $tileDirection) {
                            ForEach(FXDirection.allCases, id: \.self) { d in
                                Text(d.rawValue.capitalized).tag(d)
                            }
                        }
                        .accessibilityIdentifier("inspector.tile.direction.picker")
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                        .onChange(of: tileDirection) { commitTile() }
                        Spacer()
                    }
                }
                Stepper(value: $tileRows, in: 1...64) {
                    Text("Rows: \(tileRows)").font(.caption).lineLimit(1)
                }
                .accessibilityIdentifier("inspector.tile.rows.stepper")
                .controlSize(.small)
                .onChange(of: tileRows) { commitTile() }
                Stepper(value: $tileCols, in: 1...64) {
                    Text("Columns: \(tileCols)").font(.caption).lineLimit(1)
                }
                .accessibilityIdentifier("inspector.tile.cols.stepper")
                .controlSize(.small)
                .onChange(of: tileCols) { commitTile() }
                labeledSlider("Softness", id: "inspector.tile.softness.slider",
                              value: $tileSoftness, in: 0...1,
                              format: { String(format: "%.2f", $0) }) { commitTile() }
                Toggle("Sync to beat", isOn: $tileSyncToBeat)
                    .accessibilityIdentifier("inspector.tile.syncToBeat.toggle")
                    .font(.caption).controlSize(.small)
                    .onChange(of: tileSyncToBeat) { commitTile() }
                if tileSyncToBeat {
                    labeledSlider("Flips/beat", id: "inspector.tile.flipsPerBeat.slider",
                                  value: $tileFlipsPerBeat, in: 0.25...8,
                                  format: { String(format: "%.2f×", $0) }) { commitTile() }
                    Text("Tiles flip on the beat while the beat maker plays; free-runs at the Speed above when stopped.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    labeledSlider("Speed", id: "inspector.tile.speed.slider",
                                  value: $tileSpeed, in: 0.1...5,
                                  format: { String(format: "%.2f×", $0) }) { commitTile() }
                }
                if tileMode.usesSeed {
                    Button {
                        tileSeed = UInt64.random(in: UInt64.min...UInt64.max)
                        commitTile()
                    } label: {
                        Label("Randomize pattern", systemImage: "die.face.5")
                    }
                    .accessibilityIdentifier("inspector.tile.randomize")
                    .controlSize(.small)
                }
                Text("Punches animated holes so the layer BELOW shows through — add this over another layer.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reveal the layer beneath with an animated grid of squares (flicker/dissolve/wipe).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commitTile() {
        guard tileEnabled else { engine.setTileEffect(nil, for: sourceID); return }
        var t = TileEffect()
        t.mode = tileMode
        t.rows = tileRows
        t.cols = tileCols
        t.seed = tileSeed
        t.softness = tileSoftness
        t.speed = tileSpeed
        t.direction = tileDirection
        t.syncToBeat = tileSyncToBeat
        t.flipsPerBeat = tileFlipsPerBeat
        engine.setTileEffect(t, for: sourceID)
    }

    // MARK: Video wall (Build C: tile this source into a grid)

    private var videoWallSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Video Wall (grid)", systemImage: "square.grid.2x2")
            Toggle("Tile this source into a grid", isOn: $wallEnabled)
                .accessibilityIdentifier("inspector.wall.enable.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: wallEnabled) { commitWall() }

            if wallEnabled {
                Stepper(value: $wallRows, in: 1...16) {
                    Text("Rows: \(wallRows)").font(.caption).lineLimit(1)
                }
                .accessibilityIdentifier("inspector.wall.rows.stepper")
                .controlSize(.small)
                .onChange(of: wallRows) { commitWall() }
                Stepper(value: $wallCols, in: 1...16) {
                    Text("Columns: \(wallCols)").font(.caption).lineLimit(1)
                }
                .accessibilityIdentifier("inspector.wall.cols.stepper")
                .controlSize(.small)
                .onChange(of: wallCols) { commitWall() }
                Toggle("Mirror (kaleidoscope)", isOn: $wallMirror)
                    .accessibilityIdentifier("inspector.wall.mirror.toggle")
                    .font(.caption).controlSize(.small)
                    .onChange(of: wallMirror) { commitWall() }
            } else {
                Text("Repeat this source across a grid of cells; mirror for a kaleidoscope.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commitWall() {
        guard wallEnabled else { engine.setVideoWall(nil, for: sourceID); return }
        engine.setVideoWall(VideoWall(rows: wallRows, cols: wallCols, mirror: wallMirror),
                            for: sourceID)
    }

    // MARK: Beat pulse (BEAT_SYNC_DESIGN: scale/shake this layer on the beat)

    private var beatPulseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Beat Pulse", systemImage: "waveform.path.ecg")
            Toggle("Pulse on beat", isOn: $pulseEnabled)
                .accessibilityIdentifier("inspector.pulse.enable.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: pulseEnabled) { commitPulse() }

            if pulseEnabled {
                HStack(spacing: 8) {
                    Text("Style").font(.caption)
                    // Menu picker (never segmented).
                    Picker("", selection: $pulseStyle) {
                        ForEach(BeatPulseStyle.allCases, id: \.self) { s in
                            Text(pulseStyleLabel(s)).tag(s)
                        }
                    }
                    .accessibilityIdentifier("inspector.pulse.style.picker")
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                    .onChange(of: pulseStyle) { commitPulse() }
                    Spacer()
                }
                labeledSlider("Intensity", id: "inspector.pulse.intensity.slider",
                              value: $pulseIntensity, in: 0...2,
                              format: { String(format: "%.2f", $0) }) { commitPulse() }
                Text("Layer booms/shakes on each beat while the beat maker plays; rests untouched when stopped.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Scale or shake this layer in time with the beat maker (set BPM + play in the Sound tab).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pulseStyleLabel(_ s: BeatPulseStyle) -> String {
        switch s {
        case .bump: return "Bump (scale)"
        case .shake: return "Shake"
        case .bumpShake: return "Bump + Shake"
        }
    }

    private func commitPulse() {
        guard pulseEnabled else { engine.setBeatPulse(nil, for: sourceID); return }
        engine.setBeatPulse(BeatPulseEffect(intensity: pulseIntensity, style: pulseStyle),
                            for: sourceID)
    }

    // MARK: Overlay (MotionGraphics: lower-third / name-tag / countdown / bug)

    private var overlayKind: MGOverlayKind {
        engine.overlayConfig(for: sourceID)?.kind ?? .lowerThird
    }

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(overlayKind.label, systemImage: overlayKind.systemImage)

            // Text fields per kind (name/subtitle for the lower-third + name-tag,
            // CTA label for the subscribe bug; the countdown needs no text).
            if overlayKind == .lowerThird || overlayKind == .nameTag {
                TextField("Name", text: $overlayName)
                    .accessibilityIdentifier("inspector.overlay.name.field")
                    .textFieldStyle(.roundedBorder).lineLimit(1)
                    .onSubmit(commitOverlay)
                    .onChange(of: overlayName) { commitOverlay() }
            }
            if overlayKind == .lowerThird {
                TextField("Subtitle", text: $overlaySubtitle)
                    .accessibilityIdentifier("inspector.overlay.subtitle.field")
                    .textFieldStyle(.roundedBorder).lineLimit(1)
                    .onSubmit(commitOverlay)
                    .onChange(of: overlaySubtitle) { commitOverlay() }
            }
            if overlayKind == .subscribeBug {
                TextField("Label", text: $overlayCTA)
                    .accessibilityIdentifier("inspector.overlay.cta.field")
                    .textFieldStyle(.roundedBorder).lineLimit(1)
                    .onSubmit(commitOverlay)
                    .onChange(of: overlayCTA) { commitOverlay() }
            }
            if overlayKind == .countdown {
                Stepper(value: $overlayCountdown, in: 1...600) {
                    Text("Start at \(overlayCountdown)s").font(.caption).lineLimit(1)
                }
                .accessibilityIdentifier("inspector.overlay.countdown.stepper")
                .controlSize(.small)
                .onChange(of: overlayCountdown) { commitOverlay() }
            }

            // Corner (menu, never segmented — labels are wide).
            HStack(spacing: 8) {
                Text("Corner").font(.caption)
                Picker("", selection: $overlayCorner) {
                    ForEach(MGCorner.allCases, id: \.self) { c in
                        Text(cornerLabel(c)).tag(c)
                    }
                }
                .accessibilityIdentifier("inspector.overlay.corner.picker")
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .onChange(of: overlayCorner) { commitOverlay() }
                Spacer()
            }
            ColorPicker("Accent", selection: $overlayAccent, supportsOpacity: false)
                .accessibilityIdentifier("inspector.overlay.accent.picker")
                .onChange(of: overlayAccent) { commitOverlay() }

            // Entrance timing (slide-in / hold / slide-out), driven live off the clock.
            labeledSlider("Slide in", id: "inspector.overlay.slideIn.slider",
                          value: $overlayIn, in: 0.1...3,
                          format: { String(format: "%.1f s", $0) }) { commitOverlay() }
            labeledSlider("Hold", id: "inspector.overlay.hold.slider",
                          value: $overlayHold, in: 0...30,
                          format: { String(format: "%.1f s", $0) }) { commitOverlay() }
            labeledSlider("Slide out", id: "inspector.overlay.slideOut.slider",
                          value: $overlayOut, in: 0.1...3,
                          format: { String(format: "%.1f s", $0) }) { commitOverlay() }

            Button {
                engine.recueOverlay(for: sourceID)
            } label: {
                Label("Play / Replay", systemImage: "play.circle")
            }
            .accessibilityIdentifier("inspector.overlay.replay")
            .controlSize(.small)
            .help("Replay the slide-in / hold / slide-out from the start")
            Text("Animated broadcast overlay — the entrance plays live off the house clock.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cornerLabel(_ c: MGCorner) -> String {
        switch c {
        case .bottomLeft:  return "Bottom-left"
        case .bottomRight: return "Bottom-right"
        case .topLeft:     return "Top-left"
        case .topRight:    return "Top-right"
        }
    }

    private func commitOverlay() {
        // Preserve the immutable kind; overwrite the editable fields.
        var c = engine.overlayConfig(for: sourceID) ?? MGOverlayConfig()
        c.name = overlayName
        c.subtitle = overlaySubtitle
        c.ctaText = overlayCTA
        c.corner = overlayCorner
        let rgba = overlayAccent.rgbaColor
        c.accentR = rgba.r; c.accentG = rgba.g; c.accentB = rgba.b
        c.inSec = overlayIn; c.holdSec = overlayHold; c.outSec = overlayOut
        c.countdownSeconds = overlayCountdown
        engine.setOverlayConfig(c, for: sourceID)
    }

    // MARK: Animated logo (entrance / idle / corner / size + replay)

    private var logoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Logo", systemImage: "seal")

            HStack(spacing: 8) {
                Text("Entrance").font(.caption)
                Picker("", selection: $logoConfig.entrance) {
                    ForEach(LogoEntranceChoice.allCases) { c in Text(c.label).tag(c) }
                }
                .accessibilityIdentifier("inspector.logo.entrance.picker")
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .onChange(of: logoConfig.entrance) { commitLogo() }
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Idle").font(.caption)
                Picker("", selection: $logoConfig.idle) {
                    ForEach(LogoIdle.allCases, id: \.self) { i in Text(i.rawValue.capitalized).tag(i) }
                }
                .accessibilityIdentifier("inspector.logo.idle.picker")
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .onChange(of: logoConfig.idle) { commitLogo() }
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Corner").font(.caption)
                Picker("", selection: $logoConfig.anchor) {
                    ForEach(LogoAnchor.allCases, id: \.self) { a in Text(anchorLabel(a)).tag(a) }
                }
                .accessibilityIdentifier("inspector.logo.corner.picker")
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .onChange(of: logoConfig.anchor) { commitLogo() }
                Spacer()
            }
            labeledSlider("Size", id: "inspector.logo.size.slider",
                          value: $logoConfig.sizeFraction, in: 0.05...0.5,
                          format: { String(format: "%.0f%%", $0 * 100) }) { commitLogo() }
            labeledSlider("Slide in", id: "inspector.logo.slideIn.slider",
                          value: $logoConfig.inSec, in: 0.1...3,
                          format: { String(format: "%.1f s", $0) }) { commitLogo() }
            labeledSlider("Hold", id: "inspector.logo.hold.slider",
                          value: $logoConfig.holdSec, in: 0...30,
                          format: { String(format: "%.1f s", $0) }) { commitLogo() }
            labeledSlider("Slide out", id: "inspector.logo.slideOut.slider",
                          value: $logoConfig.outSec, in: 0.1...3,
                          format: { String(format: "%.1f s", $0) }) { commitLogo() }

            Button {
                engine.replayLogo(for: sourceID)
            } label: {
                Label("Play / Replay", systemImage: "play.circle")
            }
            .accessibilityIdentifier("inspector.logo.replay")
            .controlSize(.small)
            .help("Replay the entrance from the start")
            Text("Animated logo overlay — entrance plays live, then idles (float / pulse / shimmer / sway).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func anchorLabel(_ a: LogoAnchor) -> String {
        switch a {
        case .topLeft:     return "Top-left"
        case .topRight:    return "Top-right"
        case .bottomLeft:  return "Bottom-left"
        case .bottomRight: return "Bottom-right"
        case .center:      return "Center"
        }
    }

    private func commitLogo() { engine.setLogoConfig(logoConfig, for: sourceID) }

    // MARK: Ticker (live text + speed + position + accent)

    private var tickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Ticker", systemImage: "text.line.first.and.arrowtriangle.forward")
            TextField("Crawl text", text: $tickerText, axis: .vertical)
                .accessibilityIdentifier("inspector.ticker.text.field")
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
                .onChange(of: tickerText) { commitTicker() }
            labeledSlider("Speed", id: "inspector.ticker.speed.slider",
                          value: $tickerSpeed, in: 20...500,
                          format: { String(format: "%.0f px/s", $0) }) { commitTicker() }
            HStack(spacing: 8) {
                Text("Position").font(.caption)
                Picker("", selection: $tickerPosition) {
                    Text("Bottom").tag(TickerPosition.bottom)
                    Text("Top").tag(TickerPosition.top)
                }
                .accessibilityIdentifier("inspector.ticker.position.picker")
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .onChange(of: tickerPosition) { commitTicker() }
                Spacer()
            }
            ColorPicker("Accent", selection: $tickerAccent, supportsOpacity: false)
                .accessibilityIdentifier("inspector.ticker.accent.picker")
                .onChange(of: tickerAccent) { commitTicker() }
            Text("A news crawl scrolling right→left; the text updates live.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func commitTicker() {
        var c = engine.tickerConfig(for: sourceID) ?? TickerConfig()
        c.text = tickerText
        c.speed = tickerSpeed
        c.position = tickerPosition
        let rgba = tickerAccent.rgbaColor
        c.accentR = rgba.r; c.accentG = rgba.g; c.accentB = rgba.b
        engine.setTickerConfig(c, for: sourceID)
    }

    // MARK: Credits (speed + loop)

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Credits", systemImage: "list.bullet.rectangle")
            labeledSlider("Speed", id: "inspector.credits.speed.slider",
                          value: $creditsSpeed, in: 20...400,
                          format: { String(format: "%.0f px/s", $0) }) { commitCredits() }
            Toggle("Loop", isOn: $creditsLoop)
                .accessibilityIdentifier("inspector.credits.loop.toggle")
                .toggleStyle(.switch).controlSize(.small)
                .onChange(of: creditsLoop) { commitCredits() }
            Text("A vertical credits roll (bottom→top). Loop repeats it seamlessly.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func commitCredits() {
        var c = engine.creditsConfig(for: sourceID) ?? CreditsConfig()
        c.speed = creditsSpeed
        c.loop = creditsLoop
        engine.setCreditsConfig(c, for: sourceID)
    }

    // MARK: Text reveal (None / typewriter / word-by-word / bounce-in + duration)

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Reveal", systemImage: "textformat.abc.dottedunderline")
            HStack(spacing: 8) {
                Text("Style").font(.caption)
                // Menu picker (never segmented) — style list can be any width.
                Picker("", selection: $textRevealStyle) {
                    Text("None").tag(TextRevealStyle?.none)
                    ForEach(TextRevealStyle.allCases, id: \.self) { style in
                        Text(revealStyleLabel(style)).tag(TextRevealStyle?.some(style))
                    }
                }
                .accessibilityIdentifier("inspector.textReveal.style.picker")
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .onChange(of: textRevealStyle) { engine.setTextRevealStyle(textRevealStyle, for: sourceID) }
                Spacer()
            }
            labeledSlider("Duration", id: "inspector.textReveal.duration.slider",
                          value: $textRevealDuration, in: 0.3...4,
                          format: { String(format: "%.1f s", $0) }) {
                engine.setTextRevealDuration(textRevealDuration, for: sourceID)
            }
            .disabled(textRevealStyle == nil)

            Button {
                engine.replayTextReveal(for: sourceID)
            } label: {
                Label("Play / Replay", systemImage: "play.circle")
            }
            .accessibilityIdentifier("inspector.textReveal.replay")
            .controlSize(.small)
            .disabled(textRevealStyle == nil)
            .help("Replay the reveal animation from the start")

            Text("Animate the text in — typewriter, word-by-word, or bounce-in. None shows it static.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func revealStyleLabel(_ s: TextRevealStyle) -> String {
        switch s {
        case .typewriter:   return "Typewriter"
        case .wordByWord:   return "Word-by-word"
        case .bounceInWord: return "Bounce-in"
        }
    }

    // MARK: Per-layer motion (None / Glide / Orbit / Bounce / Float + speed)

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Motion", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            HStack(spacing: 8) {
                Text("Path").font(.caption)
                Picker("", selection: $motionKind) {
                    ForEach(LayerMotionKind.allCases) { k in Text(k.label).tag(k) }
                }
                .accessibilityIdentifier("inspector.motion.path.picker")
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .onChange(of: motionKind) { commitMotion() }
                Spacer()
            }
            if motionKind != .none {
                labeledSlider("Speed", id: "inspector.motion.speed.slider",
                              value: $motionSpeed, in: 0.1...4,
                              format: { String(format: "%.2f×", $0) }) { commitMotion() }
            }
            Text("Animate this layer along a path each frame — glide, orbit, bounce, or float.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commitMotion() {
        engine.setLayerMotion(motionKind, speed: motionSpeed, for: sourceID)
    }

    // MARK: Presenter cutout (remove background on a camera / movie source)

    private var cutoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Remove Background", systemImage: "person.and.background.dotted")
            Toggle("Cut me out (person over the layers below)", isOn: $cutoutEnabled)
                .accessibilityIdentifier("inspector.cutout.enable.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: cutoutEnabled) { commitCutout() }

            if cutoutEnabled {
                labeledSlider("Feather", id: "inspector.cutout.feather.slider",
                              value: $cutoutFeather, in: 0...64,
                              format: { "\(Int($0)) px" }) { commitCutout() }
                Toggle("Fill with a solid color", isOn: $cutoutSolid)
                    .accessibilityIdentifier("inspector.cutout.solid.toggle")
                    .font(.caption).controlSize(.small)
                    .onChange(of: cutoutSolid) { commitCutout() }
                if cutoutSolid {
                    ColorPicker("Background color", selection: $cutoutColor, supportsOpacity: false)
                        .accessibilityIdentifier("inspector.cutout.color.picker")
                        .onChange(of: cutoutColor) { commitCutout() }
                }
                Text("Segments the person and drops the background — transparent (composite over the layers beneath) or a solid fill.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Remove the background from this camera/clip so the presenter layers over the scene — no green screen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commitCutout() {
        guard cutoutEnabled else { engine.setPresenterCutout(nil, for: sourceID); return }
        let background: PresenterCutout.Background = cutoutSolid
            ? .solidColor(cutoutColor.rgbaColor)
            : .transparent
        engine.setPresenterCutout(CutoutState(feather: Float(cutoutFeather), background: background),
                                  for: sourceID)
    }

    // MARK: Strobe / flash (full-frame color flash on the beat or a free-run timer)

    private var strobeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Strobe / Flash", systemImage: "bolt.fill")
            Toggle("Enable strobe", isOn: $strobeEnabled)
                .accessibilityIdentifier("inspector.strobe.enable.toggle")
                .font(.caption).controlSize(.small)
                .onChange(of: strobeEnabled) { commitStrobe() }

            if strobeEnabled {
                labeledSlider("Intensity", id: "inspector.strobe.intensity.slider",
                              value: $strobeIntensity, in: 0...1,
                              format: { String(format: "%.2f", $0) }) { commitStrobe() }
                ColorPicker("Flash color", selection: $strobeColor, supportsOpacity: false)
                    .accessibilityIdentifier("inspector.strobe.color.picker")
                    .onChange(of: strobeColor) { commitStrobe() }
                Toggle("Sync to beat", isOn: $strobeSyncToBeat)
                    .accessibilityIdentifier("inspector.strobe.syncToBeat.toggle")
                    .font(.caption).controlSize(.small)
                    .onChange(of: strobeSyncToBeat) { commitStrobe() }
                if !strobeSyncToBeat {
                    labeledSlider("Rate", id: "inspector.strobe.rate.slider",
                                  value: $strobeRate, in: 0.5...20,
                                  format: { String(format: "%.1f Hz", $0) }) { commitStrobe() }
                }
                Text("Flashes on the beat while the beat maker plays; free-runs at the Rate when off or stopped.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Full-frame color flash pulsing on the beat (or a free-run timer).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commitStrobe() {
        guard strobeEnabled else { engine.setStrobe(nil, for: sourceID); return }
        let rgba = strobeColor.rgbaColor
        var s = StrobeEffect()
        s.intensity = strobeIntensity
        s.red = rgba.r; s.green = rgba.g; s.blue = rgba.b
        s.syncToBeat = strobeSyncToBeat
        s.freeRunHz = strobeRate
        engine.setStrobe(s, for: sourceID)
    }

    // MARK: Row builders

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// A grade slider with a live numeric readout; writes are debounced.
    /// Accessibility id derived from the (unique) grade-parameter title, e.g.
    /// `inspector.color.exposure.slider`.
    private func gradeSlider(_ title: String, value: Binding<Double>,
                             in range: ClosedRange<Double>, identity: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if !editing { commitGrade(immediate: true) }
            }
            .accessibilityIdentifier("inspector.color.\(title.lowercased()).slider")
            .onChange(of: value.wrappedValue) { commitGrade() }
        }
    }

    private func labeledSlider(_ title: String, id: String, value: Binding<Double>,
                               in range: ClosedRange<Double>,
                               format: @escaping (Double) -> String,
                               onCommit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .accessibilityIdentifier(id)
                .onChange(of: value.wrappedValue) { onCommit() }
        }
    }

    /// Lift/Gamma/Gain: three RGB channel sliders under one label. `plain` is a
    /// plain-language gloss (Shadows/Midtones/Highlights) so a first-timer who
    /// doesn't know the colorist terms still knows what each group affects.
    private func tripleGroup(_ title: String, plain: String, triple: Binding<GradeTriple>,
                             in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.medium))
                Text("· \(plain)").font(.caption).foregroundStyle(.secondary)
            }
            channelSlider("R", group: title, value: triple.red, in: range, tint: .red)
            channelSlider("G", group: title, value: triple.green, in: range, tint: .green)
            channelSlider("B", group: title, value: triple.blue, in: range, tint: .blue)
        }
    }

    private func channelSlider(_ label: String, group: String, value: Binding<Double>,
                               in range: ClosedRange<Double>, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.monospaced()).foregroundStyle(tint).frame(width: 10)
            Slider(value: value, in: range) { editing in
                if !editing { commitGrade(immediate: true) }
            }
            .accessibilityIdentifier("inspector.color.\(group.lowercased()).\(label.lowercased()).slider")
            .onChange(of: value.wrappedValue) { commitGrade() }
            .tint(tint)
        }
    }

    // MARK: Commit

    private func commitGrade(immediate: Bool = false) {
        let grade = draft
        let write = { engine.setGrade(grade, for: sourceID) }
        if immediate {
            // Cancel any pending debounced write first, otherwise a slider-drag
            // value queued ~60ms ago could fire AFTER this immediate commit and
            // overwrite it with a stale grade (W6).
            gradeDebouncer.cancel()
            write()
        } else {
            gradeDebouncer.call(write)
        }
    }

    private func commitBackground() {
        let mode: BackgroundMode?
        switch backgroundKind {
        case .none: mode = nil
        case .remove: mode = .remove
        case .blur: mode = .blur(radius: Float(blurRadius))
        case .replace: mode = .replace(color: replaceColor.backgroundReplaceRGB)
        }
        // Background-remove is mutually exclusive with the chroma + luma keys;
        // reflect that in the UI so only one keyer shows as active.
        if backgroundKind == .remove {
            if chromaEnabled { chromaEnabled = false }
            if lumaEnabled { lumaEnabled = false }
        }
        engine.setBackground(mode, for: sourceID)
    }

    /// Push the current chroma-key draft (or clear it when disabled) to the
    /// engine. A non-nil key flips this source's Layer.premultipliedAlpha true.
    private func commitChroma() {
        guard chromaEnabled else {
            engine.setChromaKey(nil, for: sourceID)
            return
        }
        // Enabling chroma is mutually exclusive with the luma key + background-
        // remove; clear those in the UI (the engine enforces it too).
        if lumaEnabled { lumaEnabled = false }
        if backgroundKind == .remove { backgroundKind = .none }
        let key = ChromaKey(keyColor: chromaColor.backgroundReplaceRGB,
                            similarity: chromaSimilarity,
                            smoothness: chromaSmoothness,
                            spillStrength: chromaSpill)
        engine.setChromaKey(key, for: sourceID)
    }

    /// Push the current luma-key draft (or clear it when disabled) to the engine.
    /// A non-nil key flips this source's Layer.premultipliedAlpha true.
    private func commitLuma() {
        guard lumaEnabled else {
            engine.setLumaKey(nil, for: sourceID)
            return
        }
        // Mutually exclusive with the chroma key + background-remove.
        if chromaEnabled { chromaEnabled = false }
        if backgroundKind == .remove { backgroundKind = .none }
        // Codex #10: clamp so low ≤ high before building the key — crossed sliders
        // would describe an empty band and key the whole source to transparent.
        let low = min(lumaLow, lumaHigh)
        let high = max(lumaLow, lumaHigh)
        let key = LumaKey(lowLuma: low, highLuma: high,
                          smoothness: lumaSmoothness, invert: lumaInvert)
        engine.setLumaKey(key, for: sourceID)
    }

    /// Adopt a preset's params into the draft and commit (enabling the key).
    private func applyLumaPreset(_ key: LumaKey) {
        lumaLow = key.lowLuma
        lumaHigh = key.highLuma
        lumaSmoothness = key.smoothness
        lumaInvert = key.invert
        lumaEnabled = true
        commitLuma()
    }

    /// Adopt a preset's params into the draft and commit (enabling the key).
    private func applyChromaPreset(_ key: ChromaKey) {
        chromaColor = Color(backgroundReplaceRGB: key.keyColor)
        chromaSimilarity = key.similarity
        chromaSmoothness = key.smoothness
        chromaSpill = key.spillStrength
        chromaEnabled = true
        commitChroma()
    }

    // MARK: State sync

    private func loadFromEngine() {
        guard let fx = engine.sourceEffects[sourceID] else { return }
        draft = fx.grade
        // Restore the LUT name + clear-button from the engine's state, so
        // reselecting a source that already has a LUT shows it instead of the
        // default "Load LUT…" with no way to clear (W11).
        lutName = fx.lut.map { $0.title ?? "LUT" } // matches the import label (Codex #4)
        switch fx.background {
        case .none: backgroundKind = .none
        case .remove: backgroundKind = .remove
        case .blur(let radius):
            backgroundKind = .blur
            blurRadius = Double(radius)
        case .replace(let color):
            backgroundKind = .replace
            replaceColor = Color(backgroundReplaceRGB: color)
        }
        if let key = fx.chromaKey {
            chromaEnabled = true
            chromaColor = Color(backgroundReplaceRGB: key.keyColor)
            chromaSimilarity = key.similarity
            chromaSmoothness = key.smoothness
            chromaSpill = key.spillStrength
        } else {
            chromaEnabled = false
        }
        if let luma = fx.lumaKey {
            lumaEnabled = true
            lumaLow = luma.lowLuma
            lumaHigh = luma.highLuma
            lumaSmoothness = luma.smoothness
            lumaInvert = luma.invert
        } else {
            lumaEnabled = false
        }
        matteView = fx.matteView
        if let tile = fx.tile {
            tileEnabled = true
            tileMode = tile.mode
            tileRows = tile.rows
            tileCols = tile.cols
            tileSeed = tile.seed
            tileSoftness = tile.softness
            tileSpeed = tile.speed
            tileDirection = tile.direction
            tileSyncToBeat = tile.syncToBeat
            tileFlipsPerBeat = tile.flipsPerBeat
        } else {
            tileEnabled = false
        }
        if let wall = fx.videoWall {
            wallEnabled = true
            wallRows = wall.rows
            wallCols = wall.cols
            wallMirror = wall.mirror
        } else {
            wallEnabled = false
        }
        if let pulse = fx.pulse {
            pulseEnabled = true
            pulseIntensity = pulse.intensity
            pulseStyle = pulse.style
        } else {
            pulseEnabled = false
        }
        // Montage params (only meaningful for a montage source).
        if engine.isMontageSource(sourceID) {
            montageInterval = engine.montageInterval(for: sourceID)
            montageTransition = engine.montageTransitionKind(for: sourceID)
            montageCrossfade = engine.montageCrossfadeDuration(for: sourceID)
            montageKenBurns = engine.montageKenBurns(for: sourceID)
            montageShuffle = engine.montageShuffle(for: sourceID)
            montageCutOnBeat = engine.montageCutOnBeat(for: sourceID)
            montageCutEvery = engine.montageCutEveryBeats(for: sourceID)
        }
        // Overlay config (only meaningful for a motion-graphics overlay source).
        if let oc = engine.overlayConfig(for: sourceID) {
            overlayName = oc.name
            overlaySubtitle = oc.subtitle
            overlayCTA = oc.ctaText
            overlayCorner = oc.corner
            overlayAccent = Color(.sRGB, red: oc.accentR, green: oc.accentG, blue: oc.accentB)
            overlayIn = oc.inSec; overlayHold = oc.holdSec; overlayOut = oc.outSec
            overlayCountdown = oc.countdownSeconds
        }
        // Logo config (animated-logo source).
        if let lc = engine.logoConfig(for: sourceID) { logoConfig = lc }
        // Ticker config (news-crawl source).
        if let tc = engine.tickerConfig(for: sourceID) {
            tickerText = tc.text
            tickerSpeed = tc.speed
            tickerPosition = tc.position
            tickerAccent = Color(.sRGB, red: tc.accentR, green: tc.accentG, blue: tc.accentB)
        }
        // Credits config (roll source).
        if let cc = engine.creditsConfig(for: sourceID) {
            creditsSpeed = cc.speed
            creditsLoop = cc.loop
        }
        // Text reveal (added text source).
        if engine.isTextSource(sourceID) {
            textRevealStyle = engine.textRevealStyle(for: sourceID)
            textRevealDuration = engine.textRevealDuration(for: sourceID)
        }
        // Character lip-sync + auto-blink.
        if engine.isCharacterSource(sourceID) {
            lipSyncEnabled = engine.isCharacterLipSyncEnabled(sourceID)
            autoBlinkEnabled = engine.isCharacterAutoBlinkEnabled(sourceID)
        }
        // Per-layer motion.
        motionKind = engine.layerMotionKind(for: sourceID)
        motionSpeed = engine.layerMotionSpeed(for: sourceID)
        // Presenter-cutout state (camera/movie sources).
        if let cut = engine.cutoutState(for: sourceID) {
            cutoutEnabled = true
            cutoutFeather = Double(cut.feather)
            if case .solidColor(let rgba) = cut.background {
                cutoutSolid = true
                cutoutColor = Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b)
            } else {
                cutoutSolid = false
            }
        } else {
            cutoutEnabled = false
        }
        // Strobe/flash effect.
        if let s = fx.strobe {
            strobeEnabled = true
            strobeIntensity = s.intensity
            strobeColor = Color(.sRGB, red: s.red, green: s.green, blue: s.blue)
            strobeSyncToBeat = s.syncToBeat
            strobeRate = s.freeRunHz
        } else {
            strobeEnabled = false
        }
    }
}

/// UI selector for `BackgroundMode?` (the enum itself carries associated values,
/// so a plain segmented control needs this flat companion).
private enum BackgroundKind: String, CaseIterable, Identifiable {
    case none, remove, blur, replace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .remove: return "Remove"
        case .blur: return "Blur"
        case .replace: return "Replace"
        }
    }
}

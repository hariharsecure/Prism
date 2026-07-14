import SwiftUI

/// Multiview monitor (v2 deliverable 2, DESIGN §2.2): one window showing the
/// live program large, plus a grid of the scene presets and saved collections
/// so an operator sees everything at once and can cut between them.
///
/// ## Rendering tradeoff (documented)
/// The engine runs a *single* compositor + render loop that produces one
/// program raster. Rendering N genuinely-independent live scene thumbnails
/// would need N extra compositor passes per frame (or N offscreen render
/// loops) — too heavy for a monitor. So the multiview shows the current
/// **program live** (large, and mirrored in the active scene's card), while the
/// other preset / collection cards are labeled, static tiles you can click to
/// make active (which then renders live). This is the "program large + labeled
/// tiles" fallback the brief calls for, not N simultaneous live renders.
struct MultiviewWindow: View {
    @EnvironmentObject private var engine: AppEngine

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    programSection
                    presetsSection
                    if !engine.sceneCollections.isEmpty { collectionsSection }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Label("Multiview", systemImage: "square.grid.2x2")
                .font(.headline)
            Spacer()
            Text("\(engine.activeSources.count) source\(engine.activeSources.count == 1 ? "" : "s") · \(engine.scene.layers.count) layer\(engine.scene.layers.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            if engine.isOnAir {
                Label("ON AIR", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Program (live, large)

    private var programSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROGRAM").font(.caption.bold()).foregroundStyle(engine.isOnAir ? .red : .secondary)
            Group {
                if engine.engineFault != nil {
                     zStackFault
                } else {
                    ProgramMonitorView(store: engine.previewStore)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(engine.isOnAir ? Color.red : Color.secondary.opacity(0.3), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 640)
        }
    }

    private var zStackFault: some View {
        ZStack {
            Color.black
            Label("Compositor unavailable", systemImage: "exclamationmark.octagon")
                .foregroundStyle(.white)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    // MARK: Scene presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SCENES").font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ScenePreset.allCases) { preset in
                    presetCard(preset)
                }
            }
        }
    }

    @ViewBuilder
    private func presetCard(_ preset: ScenePreset) -> some View {
        let isActive = engine.selectedPreset == preset
        Button {
            engine.applyPreset(preset)
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    if isActive && engine.engineFault == nil {
                        // The active scene IS the live program — mirror it.
                        ProgramMonitorView(store: engine.previewStore)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    } else {
                        ZStack {
                            Color.black.opacity(0.85)
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.title2).foregroundStyle(.tertiary)
                        }
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    }
                }
                HStack {
                    Text(preset.rawValue).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer()
                    if isActive {
                        Text("LIVE").font(.caption2.bold()).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? Color.red : Color.secondary.opacity(0.25),
                              lineWidth: isActive ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help("Switch the program to the \(preset.rawValue) preset")
    }

    // MARK: Saved collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SAVED LAYOUTS").font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(engine.sceneCollections) { collection in
                    Button {
                        engine.loadCollection(collection)
                    } label: {
                        VStack(spacing: 0) {
                            ZStack {
                                Color.black.opacity(0.85)
                                VStack(spacing: 4) {
                                    Image(systemName: "square.stack.3d.up")
                                        .font(.title2).foregroundStyle(.tertiary)
                                    Text("\(collection.scene.layers.count) layer\(collection.scene.layers.count == 1 ? "" : "s")")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            HStack {
                                Text(collection.name).font(.caption.weight(.medium)).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                        }
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Load the \(collection.name) layout")
                }
            }
        }
    }
}

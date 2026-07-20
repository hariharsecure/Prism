import PrismCompositor
import PrismCore
import SwiftUI

/// Right rail: the scene's layer stack (top-most first) with visibility,
/// z-reorder, per-layer frame presets, and the scene-level PiP presets.
struct LayerControlsView: View {
    @EnvironmentObject private var engine: AppEngine
    @EnvironmentObject private var selection: SelectionModel

    /// Top-most layer first (how switchers list layers).
    private var orderedLayers: [Layer] {
        engine.scene.layers.sorted { $0.zIndex > $1.zIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Layers").font(.headline).padding(.horizontal, 12)

            // A dropdown, not a segmented control: the right rail is too narrow
            // to show three text segments ("Side by Side" clipped off the edge).
            // A menu picker fits any rail width and reads clearly.
            HStack(spacing: 6) {
                Text("Layout").font(.subheadline).foregroundStyle(.secondary)
                Picker("Layout", selection: presetBinding) {
                    ForEach(ScenePreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .accessibilityIdentifier("layers.layout.picker")
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .help("Switch the scene layout: Fullscreen, PiP Corner, or Side by Side")

            if orderedLayers.isEmpty {
                Text("Add a source to build the scene.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                List {
                    ForEach(orderedLayers, id: \.sourceID) { layer in
                        layerRow(layer)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(.vertical, 10)
    }

    private var presetBinding: Binding<ScenePreset> {
        Binding(get: { engine.selectedPreset },
                set: { engine.applyPreset($0) })
    }

    @ViewBuilder
    private func layerRow(_ layer: Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    engine.setLayerHidden(!layer.isHidden, for: layer.sourceID)
                } label: {
                    Image(systemName: layer.isHidden ? "eye.slash" : "eye")
                }
                .accessibilityIdentifier("layers.row.visibility.toggle")
                .buttonStyle(.plain)
                .help(layer.isHidden ? "Show layer" : "Hide layer")

                Text(engine.displayName(for: layer.sourceID))
                    .lineLimit(1)
                    .foregroundStyle(layer.isHidden ? .secondary : .primary)
                    .fontWeight(selection.selectedSourceID == layer.sourceID ? .semibold : .regular)
                    .contentShape(Rectangle())
                    .onTapGesture { selection.selectedSourceID = layer.sourceID }

                Spacer()

                Button {
                    engine.moveLayer(layer.sourceID, up: true)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .accessibilityIdentifier("layers.row.moveUp")
                .buttonStyle(.plain)
                .help("Bring forward")

                Button {
                    engine.moveLayer(layer.sourceID, up: false)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityIdentifier("layers.row.moveDown")
                .buttonStyle(.plain)
                .help("Send backward")
            }

            HStack(spacing: 4) {
                ForEach(LayerFramePreset.allCases) { preset in
                    Button(preset.rawValue) {
                        engine.setLayerFrame(preset, for: layer.sourceID)
                    }
                    .accessibilityIdentifier("layers.row.frame.\(preset.rawValue)")
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Position & size this layer: \(preset.rawValue)")
                }

                Spacer(minLength: 4)

                // v2 deliverable 3: animate the layer's entrance. Picking a
                // style triggers it immediately (frames keep flowing).
                Menu {
                    ForEach(LayerEntrancePreset.allCases) { preset in
                        Button {
                            engine.animateLayerIn(sourceID: layer.sourceID,
                                                  preset: preset, duration: 0.6)
                        } label: {
                            Label(preset.rawValue, systemImage: preset.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: engine.animatingSourceID == layer.sourceID
                          ? "play.circle.fill" : "wand.and.rays")
                }
                .accessibilityIdentifier("layers.row.entrance.menu")
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.mini)
                .help("Animate this layer in (slide / fade / scale / pop)")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(selection.selectedSourceID == layer.sourceID
                    ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { selection.selectedSourceID = layer.sourceID }
    }
}

/// Transition controls (DESIGN §6, near the program monitor / cut area): enable
/// the animated crossfade and set its duration. Bound to AppEngine's transition
/// state — used by every preset switch (`applyPreset` → `commitSceneAnimated`).
struct TransitionControlsView: View {
    @EnvironmentObject private var engine: AppEngine

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { engine.transitionEnabled },
                                 set: { engine.setTransitionEnabled($0) })) {
                Label("Transition", systemImage: "arrow.left.arrow.right.square")
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("transition.enable.toggle")
            .controlSize(.small)
            .help("Animate between scene presets instead of a hard cut")

            // Transition EFFECT: a MENU picker (never segmented — the narrow-rail
            // rule) covering every TransitionKind. Compositor-native kinds
            // (dissolve/wipe/push) run exactly; pixel-effect kinds animate as a
            // crossfade for now.
            Picker("Effect", selection: Binding(
                get: { TransitionKindChoice.from(engine.transitionKind) },
                set: { engine.setTransitionKind($0.kind) })) {
                ForEach(TransitionKindChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .accessibilityIdentifier("transition.effect.picker")
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(!engine.transitionEnabled)
            .help("Choose the transition effect")

            HStack(spacing: 6) {
                Image(systemName: "timer").foregroundStyle(.secondary)
                Slider(value: Binding(get: { engine.transitionDuration },
                                      set: { engine.setTransitionDuration($0) }),
                       in: 0...2)
                    .accessibilityIdentifier("transition.duration.slider")
                    .frame(width: 120)
                    .disabled(!engine.transitionEnabled)
                Text(String(format: "%.1fs", engine.transitionDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }
            .opacity(engine.transitionEnabled ? 1 : 0.5)

            // Stinger media: when selected, every enabled scene switch uses the
            // live source as a cue-frame cover instead of the Effect picker.
            Menu {
                Button {
                    engine.setStingerMedia(nil)
                } label: {
                    if engine.stingerMediaID == nil { Label("None", systemImage: "checkmark") }
                    else { Text("None") }
                }
                ForEach(engine.activeSources.filter(\.isGenerated), id: \.id) { source in
                    Button {
                        engine.setStingerMedia(source.id)
                    } label: {
                        if engine.stingerMediaID == source.id {
                            Label(source.descriptor.name, systemImage: "checkmark")
                        } else {
                            Text(source.descriptor.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "sparkles.tv")
            }
            .accessibilityIdentifier("transition.stinger.menu")
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose live media for cue-frame stinger scene switches; choose None to use the Effect picker")

            Spacer(minLength: 0)
        }
    }
}

/// Flat, `Hashable` companion for `TransitionKind` (which carries associated
/// wipe/push directions) so a `.menu` Picker can bind to it.
enum TransitionKindChoice: String, CaseIterable, Identifiable {
    case dissolve, wipeRight, wipeLeft, pushLeft, pushRight, iris, zoomBlur, glitch, animeFlash, speedline
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dissolve: return "Dissolve"
        case .wipeRight: return "Wipe →"
        case .wipeLeft: return "Wipe ←"
        case .pushLeft: return "Push ←"
        case .pushRight: return "Push →"
        case .iris: return "Iris"
        case .zoomBlur: return "Zoom Blur"
        case .glitch: return "Glitch"
        case .animeFlash: return "Anime Flash"
        case .speedline: return "Speedline"
        }
    }
    var kind: TransitionKind {
        switch self {
        case .dissolve: return .dissolve
        case .wipeRight: return .wipe(.right)
        case .wipeLeft: return .wipe(.left)
        case .pushLeft: return .push(.left)
        case .pushRight: return .push(.right)
        case .iris: return .iris
        case .zoomBlur: return .zoomBlur
        case .glitch: return .glitch
        case .animeFlash: return .animeFlash
        case .speedline: return .speedline
        }
    }
    static func from(_ kind: TransitionKind) -> TransitionKindChoice {
        allCases.first { $0.kind == kind } ?? .dissolve
    }
}

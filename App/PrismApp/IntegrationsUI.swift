import PrismControlSurface
import PrismProximity
import SwiftUI

// MARK: - MIDI control surface panel (Integration 1)

/// Transport-bar popover: enable MIDI input, MIDI-learn a trigger per bindable
/// action, and load/save the mapping.
struct MIDIControlPanel: View {
    @EnvironmentObject private var engine: AppEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MIDI Control Surface").font(.headline)

            Toggle(isOn: Binding(get: { engine.controlSurfaceEnabled },
                                 set: { engine.setControlSurfaceEnabled($0) })) {
                Label("Enable MIDI input", systemImage: "pianokeys")
            }
            .toggleStyle(.switch)

            Text(engine.controlSurfaceEnabled
                 ? "Listening for MIDI. Tap Learn on a row, then move a control on your surface."
                 : "Enable to receive MIDI, then bind hardware controls to actions.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(AppEngine.bindableActions, id: \.action.bindingKey) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .frame(width: 172, alignment: .leading)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if engine.surfaceLearningAction?.bindingKey == row.action.bindingKey {
                        Text("Move a control…")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Cancel") { engine.cancelSurfaceLearn() }
                            .controlSize(.small)
                    } else {
                        if let trigger = engine.surfaceBindings[row.action.bindingKey] {
                            Text(trigger)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Button { engine.unbindSurfaceAction(row.action) } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Clear this binding")
                        }
                        Button("Learn") { engine.beginSurfaceLearn(for: row.action) }
                            .controlSize(.small)
                            .disabled(!engine.controlSurfaceEnabled)
                    }
                }
            }

            Divider()
            HStack {
                Button("Save Mapping") { engine.saveSurfaceMapping() }
                Button("Reload") { engine.loadSurfaceMapping() }
                Spacer()
                Text("\(engine.surfaceActionCount) actions")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}

// MARK: - Auto-Director panel (Integration 3)

struct AutoDirectorPanel: View {
    @EnvironmentObject private var engine: AppEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Auto-Director").font(.headline)

            Toggle(isOn: Binding(get: { engine.autoDirectorEnabled },
                                 set: { engine.setAutoDirectorEnabled($0) })) {
                Label("Enable auto-switching", systemImage: "wand.and.stars")
            }
            .toggleStyle(.switch)

            Text("Cuts the program to the most active source and auto-frames it. Manual control resumes when off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Sensitivity: \(engine.directorSensitivity, specifier: "%.2f")")
                    .font(.caption)
                Slider(value: Binding(get: { engine.directorSensitivity },
                                      set: { engine.setDirectorSensitivity($0) }), in: 0...1)
                Text("Sticky ← → Twitchy").font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Minimum shot: \(engine.directorMinShotSeconds, specifier: "%.1f") s")
                    .font(.caption)
                Slider(value: Binding(get: { engine.directorMinShotSeconds },
                                      set: { engine.setDirectorMinShot($0) }), in: 0...10)
            }

            Divider()
            if let active = engine.directorActiveSourceID {
                LabeledContent("On program", value: engine.displayName(for: active))
            }
            Text("\(engine.directorDecisionCount) cut\(engine.directorDecisionCount == 1 ? "" : "s") made")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: - Nearby devices (Integration 2 — BLE discovery only)

/// A `Section` for the sources sidebar listing BLE-discovered nearby iOS
/// devices. Tapping one surfaces the existing Wi-Fi pairing code — BLE is
/// discovery-only; the real pair is the QUIC short-code flow.
struct NearbyDevicesSection: View {
    @EnvironmentObject private var engine: AppEngine

    var body: some View {
        Section("Nearby (Bluetooth)") {
            Toggle(isOn: Binding(get: { engine.proximityDiscovering },
                                 set: { engine.setProximityDiscovery($0) })) {
                Label("Discover nearby devices", systemImage: "dot.radiowaves.right")
            }
            .toggleStyle(.switch)
            .font(.callout)

            if engine.proximityDiscovering && engine.proximityCandidates.isEmpty {
                Text("Searching…").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(engine.proximityCandidates, id: \.peripheralID) { candidate in
                Button { engine.nearbyTapped(candidate) } label: {
                    HStack {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                        VStack(alignment: .leading) {
                            Text(candidate.name ?? "Unknown device").lineLimit(1)
                            Text(Self.proximityLabel(candidate.proximity))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let hint = engine.nearbyHint {
                Text(hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func proximityLabel(_ bucket: ProximityBucket) -> String {
        switch bucket {
        case .immediate: return "Right here"
        case .near:      return "Nearby"
        case .far:       return "Far"
        case .unknown:   return "Unknown distance"
        }
    }
}

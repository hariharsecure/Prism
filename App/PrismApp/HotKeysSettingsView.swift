import AppKit
import SwiftUI

// MARK: - Hotkeys settings surface (⌘, → Settings window)
//
// The app had no formal Settings window; PrismApp now adds a SwiftUI
// `Settings { }` scene hosting this view (spec §4). One row per action: a
// click-to-record capture control showing the current combo + a Clear button.
// accessibilityIdentifiers follow the app convention `hotkeys.<action>.record`
// / `hotkeys.<action>.clear` (consistent with the ~185 already present).

struct HotKeysSettingsView: View {
    @EnvironmentObject private var manager: HotKeyManager
    @EnvironmentObject private var engine: AppEngine

    var body: some View {
        Form {
            CanvasSettingsSection()

            Section {
                ForEach(HotKeyAction.toggles, id: \.id) { action in
                    HotKeyRow(action: action)
                }
            } header: {
                Text("Global Hotkeys")
            } footer: {
                Text("These fire system-wide — even while another app is in front — so you can toggle record, streaming, the virtual camera, or the control server without switching back to Prism. Click a field and press the key combo to set it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !engine.sceneCollections.isEmpty {
                Section("Switch Scene Collection") {
                    ForEach(Array(engine.sceneCollections.enumerated()), id: \.element.id) { index, collection in
                        HotKeyRow(action: .switchToScene(index: index),
                                  labelOverride: "Switch to “\(collection.name)”")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .accessibilityIdentifier("hotkeys.settings.root")
    }
}

// MARK: - Canvas section (resolution + framerate)

/// Project canvas picker: resolution + framerate presets (default 1080p60).
/// Disabled while any output is on-air — changing the program raster under a
/// live, fixed-dimension encoder would corrupt the recording/stream (the
/// engine's `setCanvasConfig` re-checks this as the authoritative guard).
private struct CanvasSettingsSection: View {
    @EnvironmentObject private var engine: AppEngine

    private var resolutionBinding: Binding<CanvasConfig.Resolution> {
        Binding(
            get: { engine.canvasConfig.resolution },
            set: { engine.setCanvasConfig(CanvasConfig(resolution: $0,
                                                       frameRate: engine.canvasConfig.frameRate)) })
    }

    private var frameRateBinding: Binding<CanvasConfig.FrameRate> {
        Binding(
            get: { engine.canvasConfig.frameRate },
            set: { engine.setCanvasConfig(CanvasConfig(resolution: engine.canvasConfig.resolution,
                                                       frameRate: $0)) })
    }

    var body: some View {
        Section {
            Picker("Resolution", selection: resolutionBinding) {
                ForEach(CanvasConfig.Resolution.allCases) { res in
                    Text(res.label).tag(res)
                }
            }
            .accessibilityIdentifier("canvas.resolution.picker")

            Picker("Frame rate", selection: frameRateBinding) {
                ForEach(CanvasConfig.FrameRate.allCases) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .accessibilityIdentifier("canvas.fps.picker")
        } header: {
            Text("Canvas")
        } footer: {
            Text(engine.canChangeCanvas
                 ? "The program canvas size and framerate. Every recorder, stream, and the virtual camera follow this. Default is 1920 × 1080 at 60 fps."
                 : "Stop recording, streaming, replay, and the virtual camera to change the canvas — it can't change while you're on-air.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!engine.canChangeCanvas)
    }
}

/// One action row: label + capture control + clear button.
private struct HotKeyRow: View {
    @EnvironmentObject private var manager: HotKeyManager
    let action: HotKeyAction
    var labelOverride: String? = nil

    var body: some View {
        HStack {
            Text(labelOverride ?? action.displayName)
            Spacer()
            KeyRecorderControl(action: action)
            Button {
                manager.clear(action)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(manager.binding(for: action) == nil)
            .help("Clear this hotkey")
            .accessibilityIdentifier("hotkeys.\(action.id).clear")
        }
    }
}

/// Click-to-record capture control. While recording it installs a LOCAL NSEvent
/// keyDown monitor (app-focused, no TCC) to read the chord; the resulting
/// keyCode+modifiers are converted to the Carbon mask and handed to the manager,
/// which does the actual system-wide registration. This local monitor is only
/// the capture UI — it is NOT the global hotkey mechanism.
private struct KeyRecorderControl: View {
    @EnvironmentObject private var manager: HotKeyManager
    let action: HotKeyAction

    @State private var recording = false
    @State private var monitor: Any?

    private var currentCombo: String? {
        manager.binding(for: action).map {
            HotKeyFormatter.string(keyCode: $0.keyCode, carbonModifiers: $0.carbonModifiers)
        }
    }

    var body: some View {
        Button {
            if recording { stopRecording() } else { startRecording() }
        } label: {
            Text(recording ? "Press keys…" : (currentCombo ?? "Click to set"))
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 96)
                .padding(.vertical, 3).padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(recording ? Color.accentColor : Color.secondary.opacity(0.4),
                                lineWidth: recording ? 2 : 1))
                .foregroundStyle(currentCombo == nil && !recording ? .secondary : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hotkeys.\(action.id).record")
        .onDisappear(perform: removeMonitor)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels without binding.
            if event.keyCode == 53 { // kVK_Escape
                stopRecording()
                return nil
            }
            let carbon = HotKeyBinding.carbonModifiers(
                fromNSFlagsRawValue: event.modifierFlags.rawValue)
            let binding = HotKeyBinding(action: action,
                                        keyCode: UInt32(event.keyCode),
                                        carbonModifiers: carbon)
            manager.assign(binding)
            stopRecording()
            return nil // consume so the key doesn't also type into the window
        }
    }

    private func stopRecording() {
        recording = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

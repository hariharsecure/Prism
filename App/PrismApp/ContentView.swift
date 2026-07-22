import SwiftUI

/// Single-window layout (DESIGN §6): transport bar on top, sources rail left,
/// program monitor center, layer inspector right, status line at the bottom.
struct ContentView: View {
    @EnvironmentObject private var engine: AppEngine
    @StateObject private var selection = SelectionModel()
    @State private var mixerExpanded = true
    @State private var showGettingStarted = false
    // First-run flag: reset with
    //   defaults delete <app-bundle-id> prism.hasSeenGettingStarted
    // (or delete the whole domain) to see the Getting Started sheet again.
    @AppStorage("prism.hasSeenGettingStarted") private var hasSeenGettingStarted = false

    /// True when nothing is producing a program image yet — drives the friendly
    /// "add a source" hint painted over the (black) program monitor.
    private var hasVideoSource: Bool {
        engine.activeSources.contains(where: \.isVideo)
    }

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(showHelp: $showGettingStarted)
            Divider()

            HSplitView {
                SourcesSidebar()
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)

                VStack(spacing: 0) {
                    if let fault = engine.engineFault {
                        Label(fault, systemImage: "exclamationmark.octagon")
                            .padding()
                    } else if engine.studioMode {
                        // Studio mode: preview (left) + program (right) monitors
                        // with a TAKE button. The single-monitor branch below is
                        // left untouched for the default (non-studio) layout.
                        StudioView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        TransitionControlsView()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Divider()
                        VerticalProgramPanel()
                    } else {
                        ProgramMonitorView(store: engine.previewStore)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay { if !hasVideoSource { monitorEmptyHint } }
                            .padding(12)
                        Divider()
                        TransitionControlsView()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Divider()
                        VerticalProgramPanel()
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .background(Color(nsColor: .underPageBackgroundColor))

                // Right rail: the layer stack (selection source) above the
                // context-sensitive Inspector (DESIGN §6).
                VSplitView {
                    LayerControlsView()
                        .frame(minHeight: 160)
                    InspectorView()
                        .frame(minHeight: 200)
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
            .layoutPriority(1)

            Divider()
            BottomDrawer(expanded: $mixerExpanded)

            Divider()
            statusLine
        }
        .environmentObject(selection)
        .frame(minWidth: 1100, minHeight: 700)
        // Auto-select a freshly-added source's layer so the Inspector populates
        // immediately (no "why is this empty?" confusion).
        .onReceive(engine.$lastAddedVideoSourceID) { id in
            if let id { selection.selectedSourceID = id }
        }
        .sheet(isPresented: $showGettingStarted, onDismiss: { hasSeenGettingStarted = true }) {
            GettingStartedSheet {
                hasSeenGettingStarted = true
                showGettingStarted = false
            }
        }
        // Show the Getting Started guide automatically on first launch only.
        .onAppear {
            if !hasSeenGettingStarted { showGettingStarted = true }
        }
    }

    /// Friendly hint painted over the empty program monitor until a video
    /// source exists (item 2 — the monitor stays black otherwise).
    private var monitorEmptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.85))
            Text("Add a camera or source from the left")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
            Text("to see your program here.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))

            // One-click start: if exactly one camera is connected, offer it
            // right here so a first-timer never has to hunt the left rail.
            if let cam = engine.cameras.first, engine.cameras.count == 1 {
                Button {
                    engine.addCamera(cam)
                } label: {
                    Label("Use \(cam.name)", systemImage: "video.fill")
                }
                .accessibilityIdentifier("content.monitor.useCamera")
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        // The button needs hits; the rest of the hint is decorative.
    }

    private var statusLine: some View {
        HStack {
            if let error = engine.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("Dismiss") { engine.lastError = nil }
                    .accessibilityIdentifier("content.status.dismissError")
                    .controlSize(.mini)
            } else {
                Text(engine.canvasConfig.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("content.status.canvas")
            }
            Spacer()
            Text("\(engine.activeSources.count) source\(engine.activeSources.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

import SwiftUI

/// Phase 3a Stage 3 — the studio (preview/program) center layout.
///
/// Shown in place of the single program monitor when `engine.studioMode` is on
/// (ContentView branches on that flag; OFF keeps today's single-monitor layout
/// byte-for-byte). Two `ProgramMonitorView`s share the same view class but pull
/// from different stores:
///   - PREVIEW (left)  → `engine.previewProgramStore` (off-air `previewScene`)
///   - PROGRAM (right) → `engine.previewStore` (on-air `fanOut.preview`)
/// A prominent TAKE button between them runs the selected transition to cut the
/// off-air preview to the live program (`engine.take()`, wired in Stage 2). This
/// file is VIEW-LAYER only — it touches no engine logic or preserved seams.
struct StudioView: View {
    @EnvironmentObject private var engine: AppEngine

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                monitor(
                    title: "PREVIEW",
                    tint: .secondary,
                    store: engine.previewProgramStore,
                    identifier: "studio.monitor.preview",
                    voiceOver: "Preview monitor, off air"
                )
                monitor(
                    title: "PROGRAM",
                    tint: .red,
                    store: engine.previewStore,
                    identifier: "studio.monitor.program",
                    voiceOver: "Program monitor, on air"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            takeButton
        }
        .padding(12)
    }

    /// One captioned 16:9 monitor. `title`/`tint` render the PREVIEW/PROGRAM
    /// caption (program reads "live" — red); both reuse `ProgramMonitorView`.
    private func monitor(title: String,
                         tint: Color,
                         store: ProgramPreviewStore,
                         identifier: String,
                         voiceOver: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }

            ProgramMonitorView(store: store)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(tint.opacity(0.7), lineWidth: 2)
                )
                .accessibilityIdentifier(identifier)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(voiceOver)
        }
        .frame(maxWidth: .infinity)
    }

    /// The TAKE control: cut the off-air preview to the live program using the
    /// currently selected transition (Stage 2). Disabled defensively if studio
    /// mode is somehow off (this view only appears when it is on).
    private var takeButton: some View {
        Button {
            engine.take()
        } label: {
            Text("TAKE")
                .font(.title3.weight(.heavy))
                .frame(minWidth: 160)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [])
        .accessibilityIdentifier("studio.take.button")
        .accessibilityLabel("Take")
        .accessibilityHint("Cut the off-air preview to the live program using the selected transition.")
        .help("TAKE — send the off-air PREVIEW to the live PROGRAM using the transition/duration selected below.")
    }
}

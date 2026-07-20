import SwiftUI

/// First-run "Getting Started" guide (discoverability). A concise, native sheet
/// that maps the seven core tasks to the actual UI in plain language. Shown
/// automatically on first launch (persisted via the
/// `prism.hasSeenGettingStarted` @AppStorage flag in ContentView) and any time
/// from the "?" button in the transport bar.
struct GettingStartedSheet: View {
    /// Dismiss + mark the guide seen (so it won't auto-open on next launch).
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.tv")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Welcome to Prism").font(.title2.weight(.semibold))
                    Text("Here's how to build and go live in a few steps.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.steps) { step in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: step.icon)
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 26, alignment: .center)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(.headline)
                                Text(step.body)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("You can reopen this anytime from the ? button in the top bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Got it") { onClose() }
                    .accessibilityIdentifier("gettingStarted.gotIt")
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
    }

    // MARK: Content

    private struct Step: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private static let steps: [Step] = [
        Step(icon: "video.badge.plus",
             title: "Add your camera",
             body: "In the left rail, open Cameras and click Add next to a camera. Microphones, screens/windows, and your paired iPhone add the same way."),
        Step(icon: "plus.rectangle.on.rectangle",
             title: "Add a text, image, or browser overlay",
             body: "Use the ＋ Add Source button at the top of the left rail to drop in a title/lower-third, a still image, or a live web page."),
        Step(icon: "camera.filters",
             title: "Apply effects",
             body: "Click a layer in the Layers list (top-right) to open the Inspector. Grade its color, load a LUT, remove/blur/replace the background, or key out a green or dark backdrop with Chroma/Luma Key. Toggle View matte to tune a key's edges."),
        Step(icon: "square.on.square",
             title: "Position & reorder layers",
             body: "Drag a layer on the preview, or use the Full / Corner / Left / Right chips. Reorder with the up/down arrows, and click the eye to show or hide a layer."),
        Step(icon: "rectangle.3.group",
             title: "Switch layouts",
             body: "Use the Fullscreen / PiP Corner / Side by Side segments above the Layers list to change the scene layout. Turn on Transition for a crossfade instead of a hard cut."),
        Step(icon: "slider.vertical.3",
             title: "Mix your audio",
             body: "The mixer at the bottom has a strip per audio source — gain, mute (M), solo (S). Click Add System Audio to capture system sound, or FX on a strip to add AUv3 effect inserts."),
        Step(icon: "dot.radiowaves.left.and.right",
             title: "Go live",
             body: "Record to ~/Movies/Prism, Stream over RTMP (add a destination first), or turn on the Virtual Camera to feed Prism into other apps. Run Broadcast Check first to catch problems."),
    ]
}

import SwiftUI

/// The tabbed bottom drawer (APP_UI_DESIGN §Placement): one region, three tabs —
/// **Mixer | Sound | Memes** — instead of three new panels. The Mixer tab hosts
/// the existing `MixerDrawer` content unchanged; Sound + Memes host the new
/// PrismSound / VisualFX boards.
///
/// Layout rules honored: the tab bar is a custom pill/underline bar of buttons —
/// NOT a `.pickerStyle(.segmented)` — so it never clips text at any width, and
/// each tab's board scrolls vertically so grids never overflow the drawer height.
struct BottomDrawer: View {
    @EnvironmentObject private var engine: AppEngine
    @Binding var expanded: Bool
    @State private var tab: DrawerTab = .mixer

    enum DrawerTab: String, CaseIterable, Identifiable {
        case mixer = "Mixer"
        case sound = "Sound"
        case memes = "Memes"
        case review = "Review"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .mixer: return "slider.vertical.3"
            case .sound: return "square.grid.2x2"
            case .memes: return "face.smiling"
            case .review: return "film.stack"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider()
                switch tab {
                case .mixer: MixerDrawer(expanded: .constant(true), embedded: true)
                case .sound: SoundBoardView()
                case .memes: MemesView()
                // FLAGSHIP: Director's Cut Review & Finish (self-gates on
                // `directorsCutEnabled` — empty/CTA state when the flagship is off).
                case .review: ReviewFinishView()
                }
            }
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse the drawer" : "Expand the drawer")

            ForEach(DrawerTab.allCases) { t in
                Button {
                    tab = t
                    if !expanded { withAnimation(.easeInOut(duration: 0.15)) { expanded = true } }
                } label: {
                    Label(t.rawValue, systemImage: t.icon)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(tab == t ? Color.accentColor.opacity(0.18) : .clear,
                                    in: Capsule())
                        .foregroundStyle(tab == t ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Show the \(t.rawValue) tab")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

import AppKit
import PrismCompositor
import SwiftUI

/// Memes tab (APP_UI_DESIGN §2): a trigger GRID of meme items (thumbnail + mode
/// badge, click = trigger into the program), a "＋ Add" tile (file-pick → choose
/// mode / holdSec / placement), and the copyright note.
///
/// Layout rules: the grid is inside a vertical `ScrollView` (adaptive columns —
/// tiles wrap), labels are `.lineLimit(1)`, and the mode/placement pickers are
/// `.menu` (never segmented).
struct MemesView: View {
    @EnvironmentObject private var engine: AppEngine
    @State private var importerShown = false
    @State private var pending: PendingMeme?
    struct PendingMeme: Identifiable { let id = UUID(); let url: URL }

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 150), spacing: 10)]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(engine.memeItems) { item in memeTile(item) }
                    addTile
                }
                Text(engine.memeCopyrightNotice)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(height: 240)
        .onAppear { engine.prepareMemes() }
        .fileImporter(isPresented: $importerShown,
                      allowedContentTypes: [.image, .movie, .gif]) { result in
            if case .success(let url) = result {
                // Hold scoped access for the pick; released when the sheet finishes.
                _ = url.startAccessingSecurityScopedResource()
                pending = PendingMeme(url: url)
            }
        }
        .sheet(item: $pending) { item in
            AddMemeSheet(url: item.url, pending: $pending).environmentObject(engine)
        }
    }

    @ViewBuilder
    private func memeTile(_ item: MemeItem) -> some View {
        let isArmed = item.mode == .stinger && engine.armedStingerMemeID == item.id
        Button {
            engine.triggerMeme(id: item.id)
        } label: {
            VStack(spacing: 3) {
                thumbnail(item)
                    .frame(height: 62)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(item.name).font(.caption2).lineLimit(1)
                Text(isArmed ? "Armed · next scene" : modeBadge(item.mode))
                    .font(.system(size: 9).weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(badgeColor(item.mode).opacity(0.22), in: Capsule())
                    .foregroundStyle(badgeColor(item.mode))
                    .lineLimit(1)
            }
            .padding(6)
            .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("memes.tile.trigger")
        .buttonStyle(.plain)
        .help(item.mode == .stinger
              ? (isArmed
                 ? "Disarm \(item.name)"
                 : "Arm \(item.name) for the next scene or preset switch")
              : "Trigger \(item.name) (\(modeBadge(item.mode)))")
        .contextMenu {
            Button(item.mode == .stinger
                   ? (isArmed ? "Disarm Stinger" : "Arm for Next Scene")
                   : "Trigger") {
                engine.triggerMeme(id: item.id)
            }
            if !item.isBuiltInTemplate {
                Button("Remove", role: .destructive) { engine.removeMeme(id: item.id) }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: MemeItem) -> some View {
        if let image = NSImage(contentsOf: item.mediaURL) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.2)
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
    }

    private var addTile: some View {
        Button { importerShown = true } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.title3)
                Text("Add").font(.caption2)
            }
            .frame(height: 62).frame(maxWidth: .infinity)
            .padding(6)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("memes.add.tile")
        .buttonStyle(.plain)
        .help("Add an image / GIF / clip as a meme")
    }

    private func modeBadge(_ mode: MemeMode) -> String {
        switch mode {
        case .cutTo: return "Cut-To"
        case .insert: return "Insert"
        case .stinger: return "Stinger"
        }
    }
    private func badgeColor(_ mode: MemeMode) -> Color {
        switch mode {
        case .cutTo: return .orange
        case .insert: return .blue
        case .stinger: return .purple
        }
    }
}

// MARK: - Add meme config

/// Choose the play mode, hold, and placement for a newly picked meme file.
struct AddMemeSheet: View {
    @EnvironmentObject private var engine: AppEngine
    let url: URL
    @Binding var pending: MemesView.PendingMeme?

    @State private var mode: MemeMode = .cutTo
    @State private var holdSec: Double = 1.5
    @State private var placement: PlacementChoice = .fullscreen

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Meme").font(.headline)
            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)

            Picker("Mode", selection: $mode) {
                Text("Cut-To (full-screen take)").tag(MemeMode.cutTo)
                Text("Insert (placed overlay)").tag(MemeMode.insert)
                Text("Stinger").tag(MemeMode.stinger)
            }
            .accessibilityIdentifier("memes.addSheet.mode.picker")
            .pickerStyle(.menu)

            HStack {
                Text(mode == .stinger ? "Duration" : "Hold")
                Slider(value: $holdSec, in: 0.3...6)
                    .accessibilityIdentifier("memes.addSheet.hold.slider")
                Text(String(format: "%.1fs", holdSec)).monospacedDigit().frame(width: 40)
            }

            Picker("Placement", selection: $placement) {
                ForEach(PlacementChoice.allCases) { p in Text(p.label).tag(p) }
            }
            .accessibilityIdentifier("memes.addSheet.placement.picker")
            .pickerStyle(.menu)
            .disabled(mode != .insert)
            .help(mode == .insert ? "Where the overlay sits on the program"
                  : "Placement applies to Insert overlays")

            if mode == .stinger {
                Text("A Stinger tile arms this media for the next scene or preset switch. It covers the program, cuts to the target at the cue, then reveals it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { finish() }
                    .accessibilityIdentifier("memes.addSheet.cancel")
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    engine.addMeme(url: url, mode: mode, placement: placement.placement, holdSec: holdSec)
                    finish()
                }
                .accessibilityIdentifier("memes.addSheet.confirm")
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func finish() {
        url.stopAccessingSecurityScopedResource()
        pending = nil
    }
}

/// Flat companion for `MemePlacement` (which carries an associated corner).
enum PlacementChoice: String, CaseIterable, Identifiable {
    case fullscreen, lowerThird, topRight, bottomRight, topLeft, bottomLeft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullscreen: return "Full-screen"
        case .lowerThird: return "Lower third"
        case .topRight: return "Top-right"
        case .bottomRight: return "Bottom-right"
        case .topLeft: return "Top-left"
        case .bottomLeft: return "Bottom-left"
        }
    }
    var placement: MemePlacement {
        switch self {
        case .fullscreen: return .fullscreen
        case .lowerThird: return .lowerThird
        case .topRight: return .corner(.topRight)
        case .bottomRight: return .corner(.bottomRight)
        case .topLeft: return .corner(.topLeft)
        case .bottomLeft: return .corner(.bottomLeft)
        }
    }
}

import AppKit
import PrismCore
import PrismSources
import SwiftUI

// MARK: - Active-source classification

extension ActiveSource {
    /// A generated PrismSources source (text / image / browser).
    var isGenerated: Bool {
        if case .generated = backing { return true } else { return false }
    }
}

// MARK: - Generated-source row

/// A row for a generated source in the sidebar's "Sources" section: its name,
/// an inline live-text editor for text sources, and a remove button.
struct GeneratedSourceRow: View {
    @EnvironmentObject private var engine: AppEngine
    let active: ActiveSource
    @State private var editing = false
    @State private var draftText = ""

    private var icon: String {
        switch active.descriptor.kind {
        case .media: return "photo"
        default: return "textformat"
        }
    }

    var body: some View {
        HStack {
            Label(active.descriptor.name, systemImage: icon)
                .lineLimit(1)
            Spacer()
            if engine.isTextSource(active.id) {
                Button {
                    draftText = active.descriptor.name
                    editing.toggle()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Edit text")
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Edit Text").font(.headline)
                        TextField("Text", text: $draftText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .lineLimit(1...4)
                        HStack {
                            Spacer()
                            Button("Apply") {
                                engine.setSourceText(draftText, for: active.id)
                                editing = false
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(14)
                }
            }
            Button {
                engine.removeSource(active.id)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Remove source")
        }
    }
}

// MARK: - Add Text sheet

/// Minimal inline config for a new text/title source (DESIGN §2.1): the string,
/// a font size, and a color.
struct AddTextSheet: View {
    @EnvironmentObject private var engine: AppEngine
    @Binding var isPresented: Bool

    @State private var text = "Lower third"
    @State private var fontSize: Double = 96
    @State private var color = Color.white

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Text Source").font(.headline)
            TextField("Text ( {time} and {counter} update live )", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            HStack {
                Text("Size")
                Slider(value: $fontSize, in: 24...240)
                Text("\(Int(fontSize))").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            ColorPicker("Color", selection: $color, supportsOpacity: true)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    engine.addTextSource(text: text, fontSize: fontSize, color: color.rgbaColor)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Add Browser sheet

/// Minimal inline config for a new browser source (DESIGN §2.1): a URL.
struct AddBrowserSheet: View {
    @EnvironmentObject private var engine: AppEngine
    @Binding var isPresented: Bool

    @State private var urlString = "https://"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Browser Source").font(.headline)
            TextField("URL (https://…)", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            Text("Renders a web page (alerts, overlays) into the scene.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    engine.addBrowserSource(urlString: urlString)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlString.isEmpty || urlString == "https://")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Add Ticker sheet (news-crawl)

/// Minimal config for a new ticker source (DESIGN §2): the crawl string. Speed /
/// position / accent are tuned live in the Inspector after it's added.
struct AddTickerSheet: View {
    @EnvironmentObject private var engine: AppEngine
    @Binding var isPresented: Bool

    @State private var text = "Breaking news   •   Live now"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Ticker").font(.headline)
            TextField("Crawl text", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Text("A bar of text that scrolls right→left. Tune speed, position and accent in the Inspector.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    var config = TickerConfig()
                    config.text = text
                    engine.addTickerSource(config: config)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Add Credits sheet (roll)

/// Config for a new credits-roll source (DESIGN §2): one credit per line. Speed
/// and loop are set live in the Inspector.
struct AddCreditsSheet: View {
    @EnvironmentObject private var engine: AppEngine
    @Binding var isPresented: Bool

    @State private var text = "Directed by\nYou\n\nStarring\nThe Cast"

    private var lines: [String] {
        text.components(separatedBy: .newlines)
    }
    private var hasContent: Bool {
        lines.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Credits").font(.headline)
            Text("One credit per line — the roll scrolls them bottom→top.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Credit lines", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...12)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    var config = CreditsConfig()
                    config.lines = lines
                    engine.addCreditsSource(config: config)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasContent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Quick Scene sheet (rule-based Text-to-Scene composer)

/// Type a vibe/title (+ optional subtitle) and Generate composes a matching
/// scene from existing pieces — a lower-third overlay, a transition kind, and a
/// music bed — via `AppEngine.generateQuickScene`. A second Generate replaces
/// the previous quick-scene overlay/bed rather than stacking.
struct QuickSceneSheet: View {
    @EnvironmentObject private var engine: AppEngine
    @Binding var isPresented: Bool

    @State private var title = ""
    @State private var subtitle = ""

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Quick Scene").font(.headline)
                Text("Type a vibe or title and Generate composes a matching lower third, transition, and music bed from your existing pieces.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vibe / Title").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. Late Night Lofi Stream", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                        .onSubmit(generate)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Subtitle (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. now streaming", text: $subtitle)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                        .onSubmit(generate)
                }

                Text("Try: Breaking News · Late Night Lofi · Hype Gaming · Wedding")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let status = engine.quickSceneStatus {
                    Label(status, systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Close") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Generate", action: generate)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedTitle.isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 440, height: 340)
    }

    private func generate() {
        guard !trimmedTitle.isEmpty else { return }
        engine.generateQuickScene(title: title, subtitle: subtitle)
    }
}

// MARK: - Color bridge

extension Color {
    /// This SwiftUI color as engine-space `RGBAColor` (sRGB, 0…1).
    var rgbaColor: RGBAColor {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return RGBAColor(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                         b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

import PrismCore
import SwiftUI
import UniformTypeIdentifiers

/// Left rail (DESIGN §6): cameras + mics (hot-plugged), screen content
/// (explicit browse — the click triggers the Screen Recording TCC prompt),
/// and connected Prism Camera peers.
struct SourcesSidebar: View {
    @EnvironmentObject private var engine: AppEngine
    @State private var screenBrowserShown = false
    @State private var textSheetShown = false
    @State private var browserSheetShown = false
    @State private var imageImporterShown = false
    @State private var videoImporterShown = false
    @State private var gifImporterShown = false
    @State private var montageImporterShown = false
    @State private var logoImporterShown = false
    @State private var tickerSheetShown = false
    @State private var creditsSheetShown = false
    @State private var quickSceneSheetShown = false

    var body: some View {
        List {
            Section("Sources") {
                Menu {
                    Button { textSheetShown = true } label: { Label("Add Text…", systemImage: "textformat") }
                    Button { imageImporterShown = true } label: { Label("Add Image…", systemImage: "photo") }
                    Button { videoImporterShown = true } label: { Label("Add Video…", systemImage: "film") }
                    Button { gifImporterShown = true } label: { Label("Add GIF…", systemImage: "photo.stack") }
                    Button { montageImporterShown = true } label: { Label("Add Montage…", systemImage: "rectangle.stack.badge.play") }
                    Button { browserSheetShown = true } label: { Label("Add Browser…", systemImage: "globe") }
                    Button { engine.addCharacterSource() } label: { Label("Add Character", systemImage: "person.crop.square.badge.video") }
                    // Animated broadcast overlays (lower-third / name-tag / countdown /
                    // subscribe-bug). Each is a live MotionGraphics generated source.
                    Menu {
                        ForEach(MGOverlayKind.allCases) { kind in
                            Button { engine.addOverlaySource(kind: kind) } label: {
                                Label(kind.label, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        Label("Add Overlay…", systemImage: "rectangle.badge.plus")
                    }
                    // Animation overlays (DESIGN §1–2): logo entrance/idle, news
                    // ticker crawl, credits roll — each a live generated source.
                    Button { logoImporterShown = true } label: { Label("Add Logo…", systemImage: "seal") }
                    Button { tickerSheetShown = true } label: { Label("Add Ticker…", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { creditsSheetShown = true } label: { Label("Add Credits…", systemImage: "list.bullet.rectangle") }
                    Divider()
                    // Quick Scene (Text-to-Scene): type a vibe → composes a
                    // lower-third + transition + music bed from existing pieces.
                    Button { quickSceneSheetShown = true } label: {
                        Label("Quick Scene…", systemImage: "sparkles")
                    }
                } label: {
                    Label("Add Source", systemImage: "plus.rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("sources.sidebar.addSource.menu")
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Add a text/title, image, or browser overlay to the scene")
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

                ForEach(engine.activeSources.filter(\.isGenerated), id: \.id) { active in
                    GeneratedSourceRow(active: active)
                }
            }

            Section("Cameras") {
                if engine.cameras.isEmpty {
                    Text("No cameras").foregroundStyle(.secondary)
                }
                ForEach(engine.cameras, id: \.id) { descriptor in
                    sourceRow(descriptor, systemImage: "video", idPrefix: "sources.cameras",
                              add: { engine.addCamera(descriptor) })
                }
            }

            Section("Microphones") {
                if engine.microphones.isEmpty {
                    Text("No microphones").foregroundStyle(.secondary)
                }
                ForEach(engine.microphones, id: \.id) { descriptor in
                    sourceRow(descriptor, systemImage: "mic", idPrefix: "sources.microphones",
                              add: { engine.addMicrophone(descriptor) })
                }
            }

            Section("Screen") {
                Button {
                    engine.refreshScreenItems()
                    screenBrowserShown = true
                } label: {
                    Label("Add Display/Window…", systemImage: "macwindow.badge.plus")
                }
                .accessibilityIdentifier("sources.screen.addDisplayWindow")
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Share a display or app window (prompts for Screen Recording permission)")

                // Screen sources already on the canvas (removable here).
                ForEach(engine.activeSources.filter(\.isScreen), id: \.id) { active in
                    HStack {
                        Label(active.descriptor.name, systemImage: "macwindow")
                            .lineLimit(1)
                        Spacer()
                        removeButton(for: active.id, id: "sources.screen.remove")
                    }
                }
            }

            Section("Prism Camera Devices") {
                // Peer-connect (PrismLink) is opt-in / off by default: the Link
                // server, its TLS identity, and Bonjour advertisement only start
                // once the user flips this on.
                Toggle("Enable peer connect", isOn: Binding(
                    get: { engine.linkEnabled },
                    set: { engine.setLinkEnabled($0) }))
                    .accessibilityIdentifier("sources.link.toggle")
                    .help("Start the Prism Camera listener so iPhones can pair over Wi-Fi. Off by default.")

                if engine.linkEnabled {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pair your iPhone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(engine.pairingCodeDisplay)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .textSelection(.enabled)
                            .help("Enter this code in Prism Camera on your iPhone")
                        Text(engine.linkStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    Text("Turn on peer connect to pair an iPhone over Wi-Fi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if engine.peers.isEmpty {
                    Text("No devices connected").foregroundStyle(.secondary)
                        .font(.caption)
                }
                ForEach(engine.peers) { entry in
                    HStack {
                        Label {
                            VStack(alignment: .leading) {
                                Text(entry.name).lineLimit(1)
                                if let detail = entry.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "iphone")
                        }
                        Spacer()
                        if engine.isActive(entry.id) {
                            removeButton(for: entry.id, id: "sources.peers.remove")
                        } else {
                            addButton(id: "sources.peers.add") { engine.addPeer(entry) }
                        }
                    }
                }
            }

            // BLE-discovered nearby devices → surface the Wi-Fi pairing code.
            NearbyDevicesSection()
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $screenBrowserShown) {
            ScreenBrowserSheet(isPresented: $screenBrowserShown)
                .environmentObject(engine)
        }
        .sheet(isPresented: $textSheetShown) {
            AddTextSheet(isPresented: $textSheetShown).environmentObject(engine)
        }
        .sheet(isPresented: $browserSheetShown) {
            AddBrowserSheet(isPresented: $browserSheetShown).environmentObject(engine)
        }
        .sheet(isPresented: $quickSceneSheetShown) {
            QuickSceneSheet(isPresented: $quickSceneSheetShown).environmentObject(engine)
        }
        .sheet(isPresented: $tickerSheetShown) {
            AddTickerSheet(isPresented: $tickerSheetShown).environmentObject(engine)
        }
        .sheet(isPresented: $creditsSheetShown) {
            AddCreditsSheet(isPresented: $creditsSheetShown).environmentObject(engine)
        }
        // Logo: a PNG/image with its own transparency, animated through an
        // entrance→idle. Decoded at init but rebuilt on live style edits, so the
        // ENGINE holds the security-scoped grant for the logo's lifetime (like a
        // movie) — do NOT release it here.
        .fileImporter(isPresented: $logoImporterShown,
                      allowedContentTypes: [.png, .image]) { result in
            if case .success(let url) = result {
                engine.addLogoSource(fileURL: url)
            }
        }
        .fileImporter(isPresented: $imageImporterShown,
                      allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                // Sandbox-scoped access for user-picked files; the source loads
                // and caches the image synchronously in addImageSource, so the
                // scope can be released as soon as it returns.
                let scoped = url.startAccessingSecurityScopedResource()
                engine.addImageSource(fileURL: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        .fileImporter(isPresented: $videoImporterShown,
                      allowedContentTypes: [.movie, .video]) { result in
            if case .success(let url) = result {
                // Unlike an image, MovieSource streams from disk for its whole
                // lifetime, so the ENGINE holds the security-scoped grant until the
                // source is removed (it starts/stops the scope itself) — do NOT
                // release it here.
                engine.addMovieSource(fileURL: url)
            }
        }
        // GIF: preloaded fully at init (like an image), so the security scope can
        // be released as soon as addGIFSource returns.
        .fileImporter(isPresented: $gifImporterShown,
                      allowedContentTypes: [.gif]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                engine.addGIFSource(fileURL: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        // Montage: pick multiple images/videos, or a folder — the engine expands
        // folders, holds the security-scoped grants for the montage's lifetime,
        // and surfaces an empty/bad selection via `lastError` (no crash).
        .fileImporter(isPresented: $montageImporterShown,
                      allowedContentTypes: [.image, .movie, .video, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                engine.addMontageSource(fileURLs: urls)
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ descriptor: SourceDescriptor, systemImage: String,
                           idPrefix: String, add: @escaping () -> Void) -> some View {
        let id = SourceID(descriptor.id)
        HStack {
            Label {
                VStack(alignment: .leading) {
                    Text(descriptor.name).lineLimit(1)
                    if let detail = descriptor.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
            }
            Spacer()
            if engine.isActive(id) {
                removeButton(for: id, id: "\(idPrefix).remove")
            } else {
                addButton(name: descriptor.name, id: "\(idPrefix).add", add)
            }
        }
        .contentShape(Rectangle())
    }

    /// An explicit "Add" affordance (label + icon, not a bare glyph) so a row
    /// visibly reads as "click to add this to the scene".
    private func addButton(name: String? = nil, id: String = "sources.row.add",
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Add", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityIdentifier(id)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.accentColor)
        .help(name.map { "Add \($0) to the scene" } ?? "Add to the scene")
    }

    private func removeButton(for id: SourceID,
                              id accessibilityID: String = "sources.row.remove") -> some View {
        Button {
            engine.removeSource(id)
        } label: {
            Image(systemName: "minus.circle.fill")
        }
        .accessibilityIdentifier(accessibilityID)
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .help("Remove source")
    }
}

extension ActiveSource {
    var isScreen: Bool {
        if case .screen = backing { return true } else { return false }
    }
}

/// Modal list of shareable displays/windows. Enumeration failure (TCC denial)
/// shows guidance instead of crashing or silently failing.
struct ScreenBrowserSheet: View {
    @EnvironmentObject private var engine: AppEngine
    @Binding var isPresented: Bool
    /// Per-add option (deliverable A): capture the source's app/system audio into
    /// its own mixer channel. Default ON — for app/window capture the audio is
    /// usually the point (game/call/media). Persisted so it sticks between adds.
    @AppStorage("screen.captureAudio") private var captureAudio = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Display or Window").font(.headline)

            Toggle(isOn: $captureAudio) {
                Label("Capture audio", systemImage: "speaker.wave.2")
            }
            .accessibilityIdentifier("screenBrowser.captureAudio.toggle")
            .help("Route this source's app/system audio into the mixer as its own channel (gain/mute/solo), folded into the program mix for recording and streaming.")

            if engine.screenBrowserBusy {
                ProgressView("Looking for shareable content…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = engine.screenBrowserError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try Again") { engine.refreshScreenItems() }
                    .accessibilityIdentifier("screenBrowser.tryAgain")
            } else {
                List(engine.screenItems, id: \.id) { descriptor in
                    Button {
                        engine.addScreen(descriptor, captureAudio: captureAudio)
                        isPresented = false
                    } label: {
                        HStack {
                            Image(systemName: descriptor.kind == .display ? "display" : "macwindow")
                            VStack(alignment: .leading) {
                                Text(descriptor.name).lineLimit(1)
                                if let detail = descriptor.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("screenBrowser.item.row")
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 260)
            }

            HStack {
                Spacer()
                Button("Close") { isPresented = false }
                    .accessibilityIdentifier("screenBrowser.close")
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
    }
}

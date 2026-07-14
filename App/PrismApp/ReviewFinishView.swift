import AppKit
import AVKit
import SwiftUI

// MARK: - Director's Cut "Review & Finish" (FLAGSHIP slice-3c) — SwiftUI surface
//
// UNVERIFIED-UNTIL-EYEBALL. This whole file is the human-facing view layer:
// SwiftUI panels, the `AVPlayer` clip preview, and the macOS Share Sheet
// (`NSSharingServicePicker`). None of it is unit-tested — the deterministic logic
// lives in `ReviewFinishModel` (`ReviewFinish.swift`, fully unit-tested). Verify
// this by eyeball: candidate queue → select → preview/aspect/trim/caption →
// Approve → Export (Share Sheet / Reveal in Finder). NOTHING auto-posts.
//
// Mounted in `BottomDrawer` as the "Review" tab, gated on `directorsCutEnabled`.

/// The Review & Finish panel: a score-ranked candidate queue on the left, the
/// selected candidate's detail (preview + aspect + trim + caption + export) on the
/// right. Empty/disabled when Director's Cut is off.
struct ReviewFinishView: View {
    @EnvironmentObject private var engine: AppEngine
    // Backend is attached in `.onAppear` (the engine EnvironmentObject isn't
    // available at `@StateObject` init time).
    @StateObject private var model = ReviewFinishModel(backend: nil)

    var body: some View {
        Group {
            if engine.directorsCutEnabled {
                content
            } else {
                disabledState
            }
        }
        .frame(height: 300)
        .onAppear {
            model.attach(engine)
            model.sync(engine.highlightCandidates)
        }
        // Keep the queue in lock-step with the live capture feed.
        .onReceive(engine.$highlightCandidates) { model.sync($0) }
        // Toggling Director's Cut off empties the panel (single source of truth).
        .onReceive(engine.$directorsCutEnabled) { on in if !on { model.clear() } }
    }

    // MARK: Disabled / empty

    private var disabledState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Director's Cut is off").font(.headline)
            Text("Turn it on and Prism scores your stream for highlight moments — then review, approve, and export them here.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            Button {
                engine.setDirectorsCutEnabled(true)
            } label: {
                Label("Turn on Director's Cut", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: Content

    private var content: some View {
        HSplitView {
            queueList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detailPane
                .frame(minWidth: 360, maxWidth: .infinity)
        }
    }

    // MARK: Candidate queue (left)

    private var queueList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Highlights").font(.caption.weight(.semibold))
                Spacer()
                Text("\(model.queue.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()

            if model.queue.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles.tv").font(.title2).foregroundStyle(.secondary)
                    Text("No highlights yet").font(.caption).foregroundStyle(.secondary)
                    Text("They appear here as Prism scores your stream.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.queue) { candidate in
                        QueueRow(candidate: candidate,
                                 onApprove: { model.approve(id: candidate.id) },
                                 onReject: { model.reject(id: candidate.id) })
                            .tag(candidate.id)
                    }
                    .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Detail (right)

    @ViewBuilder
    private var detailPane: some View {
        if let candidate = model.selected {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    CandidateDetail(candidate: candidate, model: model)
                }
                .padding(14)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "hand.point.left").font(.title2).foregroundStyle(.secondary)
                Text("Select a highlight to review").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Queue row

private struct QueueRow: View {
    let candidate: HighlightCandidate
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Preview affordance (a real thumbnail render is eyeball-later; the icon
            // is the affordance — selecting the row loads the AVPlayer preview).
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.18))
                Image(systemName: "play.rectangle").foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(String(format: "%.2f", candidate.score))
                        .font(.caption.weight(.bold)).monospacedDigit()
                    Text(reasonLabel(candidate.reason))
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(String(format: "%.1fs", candidate.effectiveDuration))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    statusBadge
                }
            }
            Spacer(minLength: 4)

            if candidate.hasFinishableAsset
                && candidate.state != .approved && candidate.state != .rejected {
                Button(action: onApprove) { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(.green).help("Approve for export")
                Button(action: onReject) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(.red).help("Reject")
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Approve", action: onApprove).disabled(!candidate.hasFinishableAsset)
            Button("Reject", role: .destructive, action: onReject)
        }
    }

    private var statusBadge: some View {
        Text(candidate.reviewStatusLabel)
            .font(.system(size: 9).weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(statusColor.opacity(0.20), in: Capsule())
            .foregroundStyle(statusColor)
            .lineLimit(1)
    }

    private var statusColor: Color {
        switch candidate.state {
        case .approved: return .green
        case .rejected: return .red
        case .failed: return .red
        case .saved, .partial: return .blue
        case .scheduled, .saving: return .orange
        }
    }

    /// Humanize the dominant-signal reason (Prism's capture-time metadata — the WHY).
    private func reasonLabel(_ raw: String) -> String {
        switch raw {
        case "audioTransient": return "Audio spike"
        case "captionLaughter": return "Laughter"
        case "captionKeyword": return "Hype word"
        case "sceneCut": return "Scene cut"
        case "loudness": return "Loud moment"
        default: return raw
        }
    }
}

// MARK: - Candidate detail

private struct CandidateDetail: View {
    let candidate: HighlightCandidate
    @ObservedObject var model: ReviewFinishModel

    // Local trim editing state, synced from the candidate on selection change.
    @State private var trimIn: Double = 0
    @State private var trimOut: Double = 0
    @State private var captionText: String = ""

    var body: some View {
        // Preview of the CHOSEN aspect variant.
        CandidatePreview(url: candidate.finishURL, aspect: candidate.effectiveAspect)

        // Why this moment (the differentiator — capture-time metadata).
        whyRow

        aspectToggle
        trimControls
        captionControls
        Divider().padding(.vertical, 2)
        exportRow

        if let err = model.lastError {
            HStack(spacing: 6) {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
                Spacer()
                Button("Dismiss") { model.dismissError() }.controlSize(.mini)
            }
        }
        Spacer(minLength: 0)
    }

    // MARK: Why

    private var whyRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Why this moment").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Score \(String(format: "%.2f", candidate.score)) · \(candidate.reason) · peak @ \(String(format: "%.1fs", candidate.peakSeconds))")
                .font(.caption).monospacedDigit()
            if let note = candidate.note {
                Text(note).font(.caption2).foregroundStyle(.secondary).italic()
            }
        }
    }

    // MARK: Aspect

    private var aspectToggle: some View {
        HStack {
            Text("Aspect").font(.caption.weight(.semibold)).frame(width: 70, alignment: .leading)
            // Menu picker (never segmented — Bible/app layout rule).
            Picker("", selection: Binding(
                get: { candidate.effectiveAspect },
                set: { model.setAspect(id: candidate.id, aspect: $0) })) {
                    ForEach(HighlightAspect.allCases) { a in
                        Text(a == .horizontal ? "16:9 horizontal" : "9:16 vertical").tag(a)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 180)
            if candidate.variantURL(candidate.effectiveAspect) == nil {
                Text("no \(candidate.effectiveAspect.label) variant")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    // MARK: Trim

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Trim").font(.caption.weight(.semibold)).frame(width: 70, alignment: .leading)
                Text("in \(String(format: "%.1fs", trimIn)) · out \(String(format: "%.1fs", trimOut)) · \(String(format: "%.1fs", max(0, trimOut - trimIn)))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            Slider(value: $trimIn, in: candidate.windowStart...candidate.windowEnd) { editing in
                if !editing { commitTrim() }
            }
            Slider(value: $trimOut, in: candidate.windowStart...candidate.windowEnd) { editing in
                if !editing { commitTrim() }
            }
        }
        .onAppear { syncLocal() }
        .onChange(of: candidate.id) { _ in syncLocal() }
    }

    private func commitTrim() {
        model.setTrim(id: candidate.id, start: trimIn, end: trimOut)
    }

    // MARK: Caption

    private var captionControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Caption").font(.caption.weight(.semibold)).frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(
                    get: { candidate.effectiveCaptionStyle },
                    set: { model.setCaptionStyle(id: candidate.id, style: $0) })) {
                        ForEach(HighlightCaptionStyle.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 130)
                Spacer()
            }
            TextField("Correct the burned caption…", text: $captionText, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
                .onSubmit { model.setCaption(id: candidate.id, text: captionText) }
                .onChange(of: candidate.id) { _ in captionText = candidate.captionText ?? "" }
        }
    }

    // MARK: Export (human-approve-before-export)

    private var exportRow: some View {
        HStack(spacing: 10) {
            if candidate.state == .approved {
                Label("Approved", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
            } else {
                Button {
                    model.approve(id: candidate.id)
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .disabled(!candidate.hasFinishableAsset)
                .help(candidate.hasFinishableAsset ? "Approve this clip for export" : "No finished clip to approve yet")
            }

            Spacer()

            Button {
                if let url = model.exportTarget(id: candidate.id) {
                    ShareSheet.present(url: url)
                }
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(candidate.state != .approved)
            .help("Share the approved clip (no auto-posting)")

            Button {
                if let url = model.exportTarget(id: candidate.id) {
                    ShareSheet.revealInFinder(url)
                }
            } label: {
                Image(systemName: "folder")
            }
            .disabled(candidate.state != .approved)
            .help("Reveal the approved clip in Finder")
        }
    }

    // MARK: Local sync

    private func syncLocal() {
        trimIn = candidate.effectiveStart
        trimOut = candidate.effectiveEnd
        captionText = candidate.captionText ?? ""
    }
}

// MARK: - AVPlayer preview

/// The clip preview. Recreates its `AVPlayer` when the chosen variant URL changes.
/// UNVERIFIED-until-eyeball (real playback needs a real asset on disk).
private struct CandidatePreview: View {
    let url: URL?
    let aspect: HighlightAspect
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "film").font(.title).foregroundStyle(.white.opacity(0.6))
                    Text(url == nil ? "No \(aspect.label) clip yet" : "Preparing preview…")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .aspectRatio(aspect == .horizontal ? 16.0 / 9.0 : 9.0 / 16.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: aspect == .horizontal ? 220 : 320)
        .onAppear { rebuild() }
        .onChange(of: url) { _ in rebuild() }
    }

    private func rebuild() {
        player?.pause()
        if let url, FileManager.default.fileExists(atPath: url.path) {
            player = AVPlayer(url: url)
        } else {
            player = nil
        }
    }
}

// MARK: - Share Sheet / Reveal (AppKit)

/// macOS Share Sheet + reveal-in-Finder. The ONLY "finish" destinations in this
/// MVP — NO direct social-network posting (that's a later, separately-gated
/// feature). UNVERIFIED-until-eyeball.
enum ShareSheet {
    @MainActor static func present(url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        guard let anchor = NSApp.keyWindow?.contentView else {
            revealInFinder(url)   // fall back to Finder if there's no window to anchor to
            return
        }
        picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
    }

    @MainActor static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

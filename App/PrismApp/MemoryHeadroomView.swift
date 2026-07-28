import Combine
import PrismCore
import SwiftUI

// G1 v1b-ENFORCE-UI — make the (shipped, working) memory governor VISIBLE.
//
// Everything here is ADDITIVE + READ-ONLY over the state AppEngine already
// @Published-exposes: `memoryHeadroomState`, `memoryWarning`, `memoryLedgerSnapshot`
// (per-class breakdown), `recentDegradeEvents`, and the one structured refusal
// carrier `memoryRefusal`. No view here changes admission/degrade LOGIC, defaults,
// or the governor's behavior — it only reflects state a producer can act on.
//
// Fable's design maps to five surfaces:
//   1. HeadroomGauge          — unobtrusive transport pill (ok→quiet, warn→amber, critical→red)
//   2. HeadroomBreakdownPopover — the gauge's popover: per-class rows + budget + session log
//   3. MemoryWarningBanner    — passive, dismissible 80% banner (Fable's exact copy)
//   4. MemoryDegradeToast     — transient toast for a NEW rung-4+ (replay) degrade
//   5. Session log            — read-only degrade history (inside the popover)
// plus the refusal alert, wired via `.memoryGovernorSurfaces()`.

// MARK: - Byte + label helpers (pure formatting, no state)

enum MemoryFormat {
    /// Producer-friendly bytes: GB with one decimal ≥ 1 GB, else MB / KB.
    static func bytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(b) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        let kb = Double(b) / 1024
        return kb >= 1 ? String(format: "%.0f KB", kb) : "\(b) B"
    }

    static func mib(_ b: Int64) -> String {
        String(format: "%.0f MiB", Double(b) / 1_048_576)
    }

    /// A human, past-tense description of an applied degrade action (session log + toast).
    static func actionLabel(_ action: DegradeAction) -> String {
        switch action {
        case let .shrinkMemeCache(toBytes): return "Trimmed meme cache to \(bytes(toBytes))"
        case let .shrinkReplay(toSeconds):  return "Shortened replay to \(Int(toSeconds))s"
        case .suspendReplay:                return "Paused instant replay"
        }
    }

    /// rung-4+ = the replay commitment (shrink or suspend). rung-1 meme-cache
    /// trims are log-only (no toast), per Fable's design.
    static func isReplayDegrade(_ action: DegradeAction) -> Bool {
        switch action {
        case .shrinkReplay, .suspendReplay: return true
        case .shrinkMemeCache:              return false
        }
    }
}

/// The producer-facing grouping of the governor's LoadClasses (Fable's popover
/// rows). Covers ALL classes so the rows reconcile to the ledger total.
struct HeadroomGroup: Identifiable {
    let id: String
    let label: String
    let classes: [LoadClass]

    static let all: [HeadroomGroup] = [
        // "Recording" = the live program footprint (record + stream + audio + compositor).
        .init(id: "recording", label: "Recording",
              classes: [.programRecord, .streamEncode, .audioEngine, .compositor]),
        .init(id: "isos", label: "ISOs", classes: [.isoAngle]),
        .init(id: "replay", label: "Replay", classes: [.replayBuffer]),
        .init(id: "sources", label: "Sources",
              classes: [.sourceCaptureRes, .idleSourcePool, .liveEffectQuality]),
        .init(id: "caches", label: "Caches", classes: [.memeCache, .previewQuality]),
    ]

    func bytes(in perClass: [LoadClass: Int64]) -> Int64 {
        classes.reduce(0) { $0 + (perClass[$1] ?? 0) }
    }
}

// MARK: - 1 + 2. Headroom gauge + breakdown popover

/// A small transport-bar pill bound to `memoryHeadroomState`. Quiet when `.ok`
/// (never distracts a live producer), amber on `.warn`, red on `.critical`.
/// Never flashes, never modal. Click → the breakdown popover.
struct HeadroomGauge: View {
    @EnvironmentObject private var engine: AppEngine
    @State private var popoverShown = false

    private var state: AppEngine.MemoryHeadroomState { engine.memoryHeadroomState }

    private var tint: Color {
        switch state {
        case .ok:       return .secondary
        case .warn:     return .orange
        case .critical: return .red
        }
    }

    private var title: String {
        switch state {
        case .ok:       return "Headroom"
        case .warn:     return "Headroom low"
        case .critical: return "Memory critical"
        }
    }

    private var valueText: String {
        switch state {
        case .ok:       return "Healthy"
        case .warn:     return "Low"
        case .critical: return "Critical"
        }
    }

    var body: some View {
        Button {
            popoverShown.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                // Only show text when there's something to say — .ok stays icon-only
                // so it recedes on a busy transport bar.
                if state != .ok {
                    Text(title).font(.caption.weight(.medium)).lineLimit(1)
                }
            }
            .foregroundStyle(state == .ok ? Color.secondary : Color.white)
            .padding(.horizontal, state == .ok ? 6 : 8)
            .padding(.vertical, 3)
            .background {
                // Filled capsule only when there's a concern; .ok is a bare glyph.
                if state != .ok {
                    Capsule().fill(tint)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transport.headroom.gauge")
        .accessibilityLabel("Memory headroom")
        .accessibilityValue(valueText)
        .accessibilityHint("Show what's using memory, and how Prism protects your recording if it runs low.")
        .help(state == .ok
              ? "Headroom — memory is healthy. Click to see what's using it."
              : "\(title) — click to see what's using memory and how Prism is protecting your recording.")
        .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
            HeadroomBreakdownPopover().environmentObject(engine)
        }
    }
}

/// The gauge's popover: per-class byte rows grouped Fable's way, total vs budget,
/// and a read-only session log of degrade events. Purely reflects the snapshot.
struct HeadroomBreakdownPopover: View {
    @EnvironmentObject private var engine: AppEngine

    var body: some View {
        let snap = engine.memoryLedgerSnapshot
        VStack(alignment: .leading, spacing: 10) {
            Text("Memory Headroom").font(.headline)
            Text("Prism protects the program you're recording and your live stream first. If memory runs low it trims caches and replay — never your recording.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Per-class breakdown (grouped).
            ForEach(HeadroomGroup.all) { group in
                let bytes = group.bytes(in: snap.perClass)
                HStack {
                    Text(group.label)
                    Spacer()
                    Text(MemoryFormat.bytes(bytes))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(bytes > 0 ? .primary : .secondary)
                }
            }

            Divider()

            // Total vs budget (soft/hard reference).
            HStack {
                Text("In use").fontWeight(.semibold)
                Spacer()
                Text("\(MemoryFormat.bytes(snap.totalBytes)) of \(MemoryFormat.bytes(snap.budgetTotal))")
                    .font(.body.monospacedDigit().weight(.semibold))
            }
            HStack {
                Text("Trims start at").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(MemoryFormat.bytes(snap.softLimit))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            // Session log (read-only).
            let events = engine.recentDegradeEvents
            if !events.isEmpty {
                Divider()
                Text("This session").font(.caption.bold())
                MemorySessionLog(events: events)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// Read-only list of degrade events (timestamp + human action + reason + freed).
struct MemorySessionLog: View {
    let events: [DegradeEvent]

    var body: some View {
        // Newest first; monotonic timestamp shown as "…s ago" (the core clock is
        // process-uptime, not wall time).
        let now = ProcessInfo.processInfo.systemUptime
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(events.enumerated().reversed()), id: \.offset) { _, event in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(MemoryFormat.actionLabel(event.action))
                            .font(.caption)
                        Spacer()
                        Text("\(max(0, Int(now - event.timestamp)))s ago")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("\(event.reason) · freed \(MemoryFormat.mib(event.freedBytes))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 3. Passive warning banner (Fable's exact copy)

/// A calm, dismissible, non-modal strip shown while `memoryWarning` is true.
/// Amber accent, no alarm. Re-appears if a fresh warning episode begins.
struct MemoryWarningBanner: View {
    @EnvironmentObject private var engine: AppEngine
    @State private var dismissed = false

    var body: some View {
        Group {
            if engine.memoryWarning && !dismissed {
                HStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .foregroundStyle(.orange)
                    Text("Headroom is getting low. Prism will trim replay length and preview quality before anything you're recording is affected.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        dismissed = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("memory.warning.banner.dismiss")
                    .accessibilityLabel("Dismiss headroom notice")
                    .help("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.14))
                .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
                .accessibilityIdentifier("memory.warning.banner")
                .accessibilityElement(children: .combine)
            }
        }
        // Reset the local dismissal once the warning clears, so the NEXT episode
        // surfaces the banner again (never a permanently-muted signal).
        .onChange(of: engine.memoryWarning) {
            if !engine.memoryWarning { dismissed = false }
        }
    }
}

// MARK: - 4. Degrade toast (rung-4+ only, debounced)

/// A transient toast shown ONCE when a NEW replay-degrade event appears. rung-1
/// meme-cache trims are silent (log-only). Debounced by event timestamp so a
/// single degrade shows a single toast.
struct MemoryDegradeToast: View {
    @EnvironmentObject private var engine: AppEngine
    @State private var message: String?
    @State private var lastSeen: Double = -.greatestFiniteMagnitude
    @State private var primed = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let message {
                HStack(spacing: 8) {
                    Image(systemName: "backward.circle")
                    Text(message).font(.callout.weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(Color.orange))
                .shadow(radius: 8, y: 2)
                .padding(.top, 52)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("memory.degrade.toast")
            }
        }
        .onAppear {
            // Prime against pre-existing history so launch never toasts old events.
            if let latest = engine.recentDegradeEvents.last(where: { MemoryFormat.isReplayDegrade($0.action) }) {
                lastSeen = latest.timestamp
            }
            primed = true
        }
        .onReceive(tick) { _ in poll() }
    }

    private func poll() {
        guard primed else { return }
        guard let latest = engine.recentDegradeEvents.last(where: { MemoryFormat.isReplayDegrade($0.action) }),
              latest.timestamp > lastSeen else { return }
        lastSeen = latest.timestamp
        withAnimation { message = "Replay shortened to protect your recordings — system memory is low." }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation { if message != nil { message = nil } }
        }
    }
}

// MARK: - Surfaces modifier (refusal alert + toast overlay)

/// Attaches the two floating governor surfaces to the app's main content: the
/// refusal alert (bound to `memoryRefusal`) and the transient degrade toast.
private struct MemoryGovernorSurfaces: ViewModifier {
    @EnvironmentObject private var engine: AppEngine

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { MemoryDegradeToast().environmentObject(engine) }
            .alert("Not enough headroom for a \(engine.memoryRefusal?.thing ?? "capture")",
                   isPresented: Binding(get: { engine.memoryRefusal != nil },
                                        set: { if !$0 { engine.memoryRefusal = nil } }),
                   presenting: engine.memoryRefusal) { _ in
                // The one-click remedy button is v2; a single calm dismiss for now.
                Button("Not Now", role: .cancel) { engine.memoryRefusal = nil }
            } message: { info in
                Text("Starting it now would risk the program recording and your live stream. To make room (~\(info.gapMiB) MiB): \(info.remedy)")
            }
    }
}

extension View {
    /// Wire the refusal alert + degrade toast onto the main content view.
    func memoryGovernorSurfaces() -> some View { modifier(MemoryGovernorSurfaces()) }
}

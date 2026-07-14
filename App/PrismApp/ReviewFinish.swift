import Foundation

// MARK: - Director's Cut "Review & Finish" (FLAGSHIP slice-3c) — PURE view-model
//
// The human-in-the-loop surface that turns auto-generated highlight candidates
// (slice-3a `HighlightCandidateStore`) into approved, exportable clips.
//
// PRODUCT DECISION: auto-GENERATE + human-APPROVE-before-export. Nothing here posts
// to any social network — approval gates a local macOS Share Sheet / reveal-in-
// Finder only (`NSSharingServicePicker` lives in the SwiftUI view, never here).
//
// This file is the PURE, deterministic, unit-tested logic layer:
//   • `ReviewCandidateBackend` — the seam to the candidate store (the App engine
//     conforms; tests inject a store-backed mock over a temp dir).
//   • `StoreReviewBackend`      — a concrete backend over a slice-3a store + a
//     directory (persists the sidecar on every edit); usable by tests and by a
//     future "reopen a past session" flow.
//   • `ReviewFinishModel`       — the observable queue + detail state machine:
//     score ordering, approve/reject, reorder, trim (clamped), caption/style,
//     aspect selection, and the export-target resolution (no-op + error when the
//     chosen variant file is missing).
//
// The SwiftUI view (`ReviewFinishView`), the AVPlayer preview, and the Share Sheet
// are UNVERIFIED-until-eyeball — see `ReviewFinishView.swift`.

// MARK: - Backend seam

/// The store seam the review model mutates through. Keeping this abstract lets the
/// model be tested against a plain store + temp dir, while in the App the live
/// `AppEngine` is the backend so its `@Published highlightCandidates` stays the
/// single source of truth (an edit re-publishes + persists the sidecar).
@MainActor
protocol ReviewCandidateBackend: AnyObject {
    /// The current candidates (capture order; the model applies display ordering).
    func reviewCandidates() -> [HighlightCandidate]
    /// Apply an edit to one candidate by id, persist, and return the new snapshot.
    @discardableResult
    func applyReview(id: UUID, _ transform: (inout HighlightCandidate) -> Void) -> [HighlightCandidate]
}

/// A concrete backend over a slice-3a `HighlightCandidateStore` + a directory. Every
/// edit mutates the store and rewrites the per-session JSON sidecar atomically, so
/// review edits survive relaunch exactly like the capture-time state. `onChange`
/// lets an owner mirror the snapshot into a `@Published` for the UI.
@MainActor
final class StoreReviewBackend: ReviewCandidateBackend {
    let store: HighlightCandidateStore
    let directory: URL
    private let onChange: ([HighlightCandidate]) -> Void

    init(store: HighlightCandidateStore, directory: URL,
         onChange: @escaping ([HighlightCandidate]) -> Void = { _ in }) {
        self.store = store
        self.directory = directory
        self.onChange = onChange
    }

    func reviewCandidates() -> [HighlightCandidate] { store.all() }

    @discardableResult
    func applyReview(id: UUID, _ transform: (inout HighlightCandidate) -> Void) -> [HighlightCandidate] {
        let updated = store.update(id: id, transform)
        store.persist(in: directory)
        onChange(updated)
        return updated
    }
}

// MARK: - View-model

/// The observable Review & Finish queue + detail state. Pure logic (no AVFoundation,
/// no AppKit) so it unit-tests deterministically. The view binds to `queue`,
/// `selectedID`, and `lastError`.
@MainActor
final class ReviewFinishModel: ObservableObject {
    /// The candidate queue in DISPLAY order (score-ranked by default; a manual
    /// reorder overrides). Approve/reject/trim/caption/aspect update elements in
    /// place, preserving order.
    @Published private(set) var queue: [HighlightCandidate] = []
    /// The candidate shown in the detail pane.
    @Published var selectedID: UUID?
    /// A user-facing error surfaced by a failed action (missing file, no asset).
    /// Never throws / crashes — every failure lands here.
    @Published private(set) var lastError: String?

    // Strong: the model is owned by its SwiftUI view (`@StateObject`), and the
    // backend (the live `AppEngine`, or a store-backed backend) never references the
    // model — so there is no retain cycle, and the backend must outlive edits.
    private var backend: ReviewCandidateBackend?
    /// File-existence probe (injected in tests so no real file is required).
    private let fileExists: (URL) -> Bool
    /// True once a manual reorder has happened — thereafter new candidates append
    /// (keeping the human's order) rather than re-sorting the whole list.
    private var manuallyReordered = false

    init(backend: ReviewCandidateBackend?,
         fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.backend = backend
        self.fileExists = fileExists
    }

    /// Attach/replace the backend (the view sets the live engine once available).
    func attach(_ backend: ReviewCandidateBackend?) { self.backend = backend }

    var selected: HighlightCandidate? {
        guard let id = selectedID else { return nil }
        return queue.first { $0.id == id }
    }

    // MARK: Ordering / sync

    /// Stable score-descending ordering (ties keep incoming order).
    static func scoreOrdered(_ candidates: [HighlightCandidate]) -> [HighlightCandidate] {
        candidates.enumerated()
            .sorted { a, b in
                if a.element.score != b.element.score { return a.element.score > b.element.score }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// Reconcile the display queue with the latest snapshot (from the live
    /// `@Published`, or `backend.reviewCandidates()`). Preserves the current display
    /// order for candidates that still exist, drops removed ones, and appends new
    /// candidates score-ranked (or in insertion order after a manual reorder).
    func sync(_ incoming: [HighlightCandidate]) {
        let byID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })

        if queue.isEmpty {
            queue = Self.scoreOrdered(incoming)
        } else {
            // Keep existing order for still-present ids (with refreshed values).
            var next: [HighlightCandidate] = queue.compactMap { byID[$0.id] }
            let known = Set(next.map(\.id))
            let fresh = incoming.filter { !known.contains($0.id) }
            next.append(contentsOf: manuallyReordered ? fresh : Self.scoreOrdered(fresh))
            queue = next
        }

        // Keep the selection valid; default to the first reviewable candidate.
        if let id = selectedID, byID[id] == nil { selectedID = nil }
        if selectedID == nil { selectedID = queue.first { $0.hasFinishableAsset }?.id ?? queue.first?.id }
    }

    /// Pull the latest snapshot straight from the backend.
    func refresh() { sync(backend?.reviewCandidates() ?? []) }

    /// Empty the panel (Director's Cut toggled off → nothing to review).
    func clear() {
        queue = []
        selectedID = nil
        lastError = nil
        manuallyReordered = false
    }

    /// Manual reorder (SwiftUI `.onMove`). Order is a review-session display concern
    /// (the store stays insertion-ordered); marking `manuallyReordered` stops later
    /// syncs from re-sorting the human's arrangement.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        manuallyReordered = true
    }

    // MARK: Approve / reject

    /// Approve a candidate for export. Requires a finished asset — approving a
    /// failed/asset-less candidate is a no-op that surfaces an error.
    @discardableResult
    func approve(id: UUID) -> Bool {
        guard let c = queue.first(where: { $0.id == id }) else { return fail("Candidate not found.") }
        guard c.hasFinishableAsset else { return fail("This candidate has no finished clip to approve.") }
        lastError = nil
        applyAndSync(id: id) { $0.state = .approved }
        return true
    }

    /// Reject a candidate (drop it from the finish queue). Allowed from any state.
    @discardableResult
    func reject(id: UUID) -> Bool {
        guard queue.contains(where: { $0.id == id }) else { return fail("Candidate not found.") }
        lastError = nil
        applyAndSync(id: id) { $0.state = .rejected }
        return true
    }

    // MARK: Trim

    /// Clamp a requested trim to `[lower, upper]` and enforce `start ≤ end`.
    static func clampTrim(start: Double, end: Double,
                          lower: Double, upper: Double) -> (start: Double, end: Double) {
        let lo = min(lower, upper), hi = max(lower, upper)
        let s = min(max(start, lo), hi)
        let e = min(max(end, lo), hi)
        return (s, max(s, e))   // out never before in
    }

    /// Set the trim in/out for a candidate, clamped within its captured window
    /// `[windowStart, windowEnd]` with in ≤ out. We can only trim WITHIN what was
    /// captured (the ring holds no more), so the bounds are the captured window.
    @discardableResult
    func setTrim(id: UUID, start: Double, end: Double) -> Bool {
        guard let c = queue.first(where: { $0.id == id }) else { return fail("Candidate not found.") }
        let clamped = Self.clampTrim(start: start, end: end, lower: c.windowStart, upper: c.windowEnd)
        lastError = nil
        applyAndSync(id: id) { $0.trimStart = clamped.start; $0.trimEnd = clamped.end }
        return true
    }

    // MARK: Caption / style / aspect

    @discardableResult
    func setCaption(id: UUID, text: String) -> Bool {
        guard queue.contains(where: { $0.id == id }) else { return fail("Candidate not found.") }
        lastError = nil
        applyAndSync(id: id) { $0.captionText = text }
        return true
    }

    @discardableResult
    func setCaptionStyle(id: UUID, style: HighlightCaptionStyle) -> Bool {
        guard queue.contains(where: { $0.id == id }) else { return fail("Candidate not found.") }
        lastError = nil
        applyAndSync(id: id) { $0.captionStyle = style }
        return true
    }

    @discardableResult
    func setAspect(id: UUID, aspect: HighlightAspect) -> Bool {
        guard queue.contains(where: { $0.id == id }) else { return fail("Candidate not found.") }
        lastError = nil
        applyAndSync(id: id) { $0.selectedAspect = aspect }
        return true
    }

    // MARK: Export (human-approve-before-export)

    /// Resolve the export target for a candidate: the chosen-aspect variant URL of
    /// an APPROVED clip whose file exists. Returns `nil` (a no-op) and surfaces an
    /// error when the clip isn't approved, has no such variant, or the file is
    /// missing — the view then does nothing (no Share Sheet, no crash).
    ///
    /// This is the only gate to export: nothing is shareable until a human approved
    /// it, encoding "auto-generate + human-approve-before-post".
    func exportTarget(id: UUID) -> URL? {
        guard let c = queue.first(where: { $0.id == id }) else { return fail(nil, "Candidate not found.") }
        guard c.state == .approved else { return fail(nil, "Approve the clip before exporting.") }
        let aspect = c.effectiveAspect
        guard let url = c.variantURL(aspect) else {
            return fail(nil, "This clip has no \(aspect.label) variant to export.")
        }
        guard fileExists(url) else {
            return fail(nil, "The \(aspect.label) file is missing on disk — nothing exported.")
        }
        lastError = nil
        return url
    }

    func dismissError() { lastError = nil }

    // MARK: Private

    /// Apply an edit through the backend and reflect the returned snapshot in the
    /// display queue IN PLACE (order preserved). Falls back to a local edit if no
    /// backend is attached (keeps the UI responsive; nothing persisted).
    private func applyAndSync(id: UUID, _ transform: (inout HighlightCandidate) -> Void) {
        let snapshot: [HighlightCandidate]
        if let backend {
            snapshot = backend.applyReview(id: id, transform)
        } else {
            var local = queue
            if let i = local.firstIndex(where: { $0.id == id }) { transform(&local[i]) }
            snapshot = local
        }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        queue = queue.compactMap { byID[$0.id] }
    }

    @discardableResult
    private func fail(_ message: String) -> Bool { lastError = message; return false }
    @discardableResult
    private func fail(_ url: URL?, _ message: String) -> URL? { lastError = message; return url }
}

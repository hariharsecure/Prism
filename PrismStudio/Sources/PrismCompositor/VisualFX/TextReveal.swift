import Foundation

/// How text is progressively revealed as a `progress ∈ 0…1` advances
/// (DESIGN.md §5). Pure/deterministic — the renderer (overlay/caption/ticker)
/// consumes the result; nothing here draws.
public enum TextRevealStyle: String, Sendable, CaseIterable {
    /// Character-by-character (the classic typewriter).
    case typewriter
    /// Word-by-word fade + slide-up.
    case wordByWord
    /// Word-by-word with a per-word bounce (`backOut` scale overshoot).
    case bounceInWord
}

/// One revealed unit (a character for `typewriter`, a word for the word styles)
/// with its per-unit animation state. `offsetX`/`offsetY` are normalized slide
/// offsets (fraction of the unit's own size) the renderer applies; `scale` is a
/// per-unit scale about its center.
public struct RevealUnit: Sendable, Equatable {
    /// The unit's text (a character or a word).
    public var text: String
    /// 0 = not yet revealed, 1 = fully in. In-between = mid reveal.
    public var alpha: Double
    /// Horizontal slide offset (fraction of the unit width; settles to 0).
    public var offsetX: Double
    /// Vertical slide offset (fraction of the unit height; settles to 0).
    public var offsetY: Double
    /// Per-unit scale about its center (1 = rest).
    public var scale: Double

    public init(text: String, alpha: Double, offsetX: Double = 0, offsetY: Double = 0, scale: Double = 1) {
        self.text = text; self.alpha = alpha
        self.offsetX = offsetX; self.offsetY = offsetY; self.scale = scale
    }

    /// Whether this unit is at all visible (alpha above a tiny epsilon).
    public var isVisible: Bool { alpha > 0.001 }
}

/// The result of a reveal: the fully-visible substring/word-set plus the
/// per-unit animation state for a smooth edge.
public struct TextRevealResult: Sendable, Equatable {
    /// The visible text so far (a prefix substring for `typewriter`; the visible
    /// words joined by spaces for the word styles). Equals the full string at
    /// `progress == 1`.
    public var visibleString: String
    /// Per-unit state (characters for `typewriter`, words otherwise), in order.
    public var units: [RevealUnit]

    /// Count of units that are at all visible.
    public var visibleCount: Int { units.reduce(0) { $0 + ($1.isVisible ? 1 : 0) } }
}

/// Reveal helpers (DESIGN.md §5). Given a full string, a `progress ∈ 0…1` and a
/// style, returns which characters/words are visible and each unit's alpha /
/// slide / scale. Deterministic and allocation-light.
public enum TextReveal {

    /// Reveal `full` at `progress` in the given `style`.
    ///
    /// Unit timing: unit `i` of `N` reveals over its slice `[i/N, (i+1)/N]`; its
    /// local progress `l = clamp((p − i/N)·N, 0, 1)` drives alpha/slide/scale. So
    /// exactly `⌈p·N⌉` units are visible (`l > 0`) at progress `p`, and every unit
    /// is fully in at `p = 1`.
    public static func reveal(_ full: String, progress: Double, style: TextRevealStyle) -> TextRevealResult {
        let p = min(max(progress, 0), 1)
        switch style {
        case .typewriter:
            return typewriter(full, p: p)
        case .wordByWord:
            return words(full, p: p, bounce: false)
        case .bounceInWord:
            return words(full, p: p, bounce: true)
        }
    }

    // MARK: - Typewriter (char-by-char)

    private static func typewriter(_ full: String, p: Double) -> TextRevealResult {
        let chars = Array(full)
        let n = chars.count
        guard n > 0 else { return TextRevealResult(visibleString: "", units: []) }
        var units: [RevealUnit] = []
        units.reserveCapacity(n)
        var visibleEnd = 0
        for i in 0..<n {
            let l = localProgress(i: i, n: n, p: p)
            let a = l                                   // simple fade for the edge char
            units.append(RevealUnit(text: String(chars[i]), alpha: a))
            if a > 0.001 { visibleEnd = i + 1 }         // prefix length that is visible
        }
        return TextRevealResult(visibleString: String(chars[0..<visibleEnd]), units: units)
    }

    // MARK: - Word-by-word (fade+slide, optional bounce)

    private static func words(_ full: String, p: Double, bounce: Bool) -> TextRevealResult {
        // Word units are the non-empty runs between single spaces. `split` returns
        // Substrings that keep their indices INTO `full`, so we reconstruct the
        // revealed `visibleString` as a growing PREFIX of the ORIGINAL string —
        // never a normalized token join. This preserves leading/interior/trailing
        // and non-space (newline) whitespace exactly, and guarantees the public
        // contract: at progress 1 `visibleString == full` byte-for-byte (F18).
        let ws = full.split(separator: " ", omittingEmptySubsequences: true)
        let n = ws.count
        // No word units (empty or all-whitespace input): there is nothing to
        // reveal progressively, so the whole string is structural whitespace with
        // no glyphs. The public contract requires `visibleString == full` at
        // progress 1; with zero units every progress is trivially "all units
        // revealed", so return the ORIGINAL string exactly (not "") — otherwise
        // `reveal("   ", progress: 1, .word) == ""` violates the F18 contract. (F18)
        guard n > 0 else { return TextRevealResult(visibleString: full, units: []) }
        var units: [RevealUnit] = []
        units.reserveCapacity(n)
        var visibleCount = 0
        var lastVisibleEnd = full.startIndex   // end of the last revealed word
        for i in 0..<n {
            let l = localProgress(i: i, n: n, p: p)
            let a = Easing.easeOut.apply(l)
            let scale: Double
            let offY: Double
            if bounce {
                // backOut overshoot on the per-word scale; no slide (the bounce is the motion).
                scale = l > 0 ? 0.6 + 0.4 * Easing.backOutDefault.apply(l) : 0.6
                offY = 0
            } else {
                // Slide up: starts 0.6 of its height below, settles to 0.
                scale = 1
                offY = (1 - Easing.easeOut.apply(l)) * 0.6
            }
            units.append(RevealUnit(text: String(ws[i]), alpha: a, offsetX: 0, offsetY: offY, scale: scale))
            // Reveal is a left-to-right prefix (unit i is visible iff p > i/n), so
            // the visible words are always a leading run.
            if a > 0.001 { visibleCount += 1; lastVisibleEnd = ws[i].endIndex }
        }
        // Cut the original string to the revealed prefix. When every word is in,
        // extend to the FULL end (so trailing whitespace after the last word is
        // included and progress-1 == the original exactly); otherwise stop at the
        // end of the last revealed word (dropping only not-yet-revealed content).
        let end = visibleCount == n ? full.endIndex : lastVisibleEnd
        let visibleString = String(full[full.startIndex..<end])
        return TextRevealResult(visibleString: visibleString, units: units)
    }

    /// Local progress of unit `i` of `n` at global progress `p` (its `[i/n,
    /// (i+1)/n]` slice mapped to `0…1`).
    private static func localProgress(i: Int, n: Int, p: Double) -> Double {
        let start = Double(i) / Double(n)
        let local = (p - start) * Double(n)
        return min(max(local, 0), 1)
    }
}

import AppKit
import ApplicationServices

/// UI-SNAPSHOT REGRESSION HARNESS (instrumentation only — no product view/engine
/// change). Two debug-only launch hooks, siblings of the `PRISM_DEBUG_*` hooks in
/// `PrismApp.swift` (env-gated, no-op without the var, Timer-not-asyncAfter):
///
///   PRISM_DEBUG_UI_STATE=<name>  drives the app into a named UI state at launch,
///     using the REAL engine mutators (+ @AppStorage / in-window AX presses / the
///     Multiview menu command) BEFORE the `PRISM_DEBUG_SCREENSHOT` timer fires.
///   PRISM_DEBUG_AX_DUMP=<file>   walks the app's OWN window AX tree → JSON and
///     audits it (no-name / <20pt / offscreen interactive controls), then quits.
///
/// Both are unreachable in normal use (no env var set).
@MainActor
enum PrismDebugUIState {
    /// The named states the capture harness iterates. Kept in one place so the
    /// shell harness and this driver never drift.
    static let allStates = [
        "empty", "one-test-source", "inspector-camera", "mixer-expanded",
        "soundboard", "memes", "destinations-sheet", "review-finish",
        "studio", "multiview", "engine-fault", "getting-started", "movie-feed",
    ]

    /// Apply `name` to `engine`. Engine/UserDefaults mutations happen immediately;
    /// state that lives in view-local `@State` (drawer tab, stream popover) or a
    /// separate window (Multiview) is driven after a short delay, once the view
    /// tree exists, via the app's OWN accessibility tree / the menu command.
    static func apply(_ name: String, engine: AppEngine) {
        // Getting Started sheet is gated on the `prism.hasSeenGettingStarted`
        // @AppStorage flag. The HARNESS passes it via the NSArgumentDomain
        // (-prism.hasSeenGettingStarted YES/NO), which is checked BEFORE the
        // persistent domain and is per-process — so back-to-back state runs are
        // deterministic (the shared on-disk default races across rapid processes).
        // This persistent write is only a best-effort fallback for a lone manual
        // run; when the arg is present it wins and this is ignored.
        if UserDefaults.standard.object(forKey: "prism.hasSeenGettingStarted") == nil
            || ProcessInfo.processInfo.arguments.allSatisfy({ !$0.contains("hasSeenGettingStarted") }) {
            UserDefaults.standard.set(name != "getting-started", forKey: "prism.hasSeenGettingStarted")
        }

        // A generated live-clock source so the monitor/mixer/inspector aren't just
        // black/empty (mirrors PRISM_DEBUG_ADD_TEXT). registerGenerated sets
        // lastAddedVideoSourceID, which ContentView auto-selects → Inspector fills.
        func addTestSource() { engine.addTextSource(text: "PRISM {time}", fontSize: 120, color: .white) }

        // A REAL decoded video file fed through the production MovieSource path, so
        // a screenshot shows the actual compositor rendering real frames (the
        // simulated-camera visual pass). The path comes from PRISM_DEBUG_MOVIE_FILE
        // so no asset path is baked in; missing/unset falls back to the generated
        // source (still a non-empty monitor).
        func addMovieFeed() {
            if let p = ProcessInfo.processInfo.environment["PRISM_DEBUG_MOVIE_FILE"],
               !p.isEmpty, FileManager.default.fileExists(atPath: p) {
                engine.addMovieSource(fileURL: URL(fileURLWithPath: p), loop: true)
            } else {
                NSLog("PRISM_DEBUG_UI_STATE[movie-feed]: PRISM_DEBUG_MOVIE_FILE unset/missing — using generated source")
                addTestSource()
            }
        }

        switch name {
        case "empty", "getting-started":
            break
        case "one-test-source", "soundboard", "memes", "destinations-sheet":
            addTestSource()
        case "mixer-expanded":
            addTestSource()
            engine.addTextSource(text: "SOURCE 2", fontSize: 90, color: .white)
        case "inspector-camera":
            // Prefer a real camera (Inspector then shows camera controls); on a
            // camera-less box fall back to the generated source (still selected).
            if let cam = engine.cameras.first { engine.addCamera(cam) } else { addTestSource() }
        case "review-finish":
            addTestSource()
            engine.setDirectorsCutEnabled(true)   // flagship ON → Review tab is populated
        case "studio":
            addTestSource()
            engine.studioMode = true              // dual preview/program layout
        case "multiview":
            addTestSource()
        case "movie-feed":
            addMovieFeed()
        case "engine-fault":
            // The status-line error surface (spec's "lastError set"). `engineFault`
            // is private(set); lastError is the public, view-mutated error channel.
            engine.lastError = "Simulated engine fault (PRISM_DEBUG_UI_STATE=engine-fault)"
        default:
            NSLog("PRISM_DEBUG_UI_STATE: unknown state '\(name)' — treated as empty")
        }

        // Deferred, view-tree-dependent actions. The bottom-drawer tab and the
        // stream popover are view-local @State with no engine hook, so we press
        // the real control by its accessibilityIdentifier through the app's own AX
        // tree — the exact path a click takes, no view code touched.
        let pressIdentifier: String?
        switch name {
        case "soundboard": pressIdentifier = "drawer.tab.sound"
        case "memes": pressIdentifier = "drawer.tab.memes"
        case "review-finish": pressIdentifier = "drawer.tab.review"
        case "destinations-sheet": pressIdentifier = "transport.stream.button"
        default: pressIdentifier = nil
        }
        let openMultiview = (name == "multiview")

        guard pressIdentifier != nil || openMultiview else { return }
        Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                if openMultiview { openMultiviewWindow() }
                if let id = pressIdentifier {
                    // Drive the control by a SYNTHETIC MOUSE CLICK at its screen
                    // frame, not an AX press: AXUIElementPerformAction runs the
                    // SwiftUI action on the AX server thread, where ButtonAction's
                    // MainActor.assumeIsolated traps; the NSAccessibility protocol
                    // sees an unbuilt tree (SwiftUI builds a11y lazily, only for a
                    // MIG client). So: find the frame via the MIG API (off-main —
                    // it round-trips the main runloop), then click on the main actor.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let rect = PrismDebugAX.screenFrame(ofIdentifier: id)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if rect == nil || !clickScreenRect(rect!) {
                                    NSLog("PRISM_DEBUG_UI_STATE: click '\(id)' failed (rect=\(String(describing: rect)))")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Open the Multiview monitor by invoking its SwiftUI menu command through the
    /// AppKit menu (openWindow(id:) isn't reachable outside a SwiftUI Environment).
    private static func openMultiviewWindow() {
        guard let menu = NSApp.mainMenu, !performMenuItem(titled: "Multiview Monitor", in: menu) else { return }
        NSLog("PRISM_DEBUG_UI_STATE: 'Multiview Monitor' menu item not found")
    }

    /// Synthesize a left mouse down+up at the center of `rect` (AX screen coords,
    /// top-left origin) delivered to the owning window on the main thread — the
    /// real event path a user click takes, so SwiftUI's gesture/action fires on
    /// the main actor. Returns false if no visible window contains the point.
    static func clickScreenRect(_ rect: CGRect) -> Bool {
        // AX origin is top-left of the primary (menu-bar / (0,0)) screen; AppKit
        // is bottom-left. Flip Y about that screen's height.
        guard let zero = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return false }
        let flippedY = zero.frame.maxY - rect.midY
        let globalPoint = CGPoint(x: rect.midX, y: flippedY)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(globalPoint) })
        else { return false }
        let local = CGPoint(x: globalPoint.x - window.frame.minX, y: globalPoint.y - window.frame.minY)
        let t = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType, _ pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: local, modifierFlags: [], timestamp: t,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: pressure)
        }
        guard let down = ev(.leftMouseDown, 1), let up = ev(.leftMouseUp, 0) else { return false }
        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    private static func performMenuItem(titled title: String, in menu: NSMenu) -> Bool {
        menu.update() // let SwiftUI populate/enable the synthesized items
        for item in menu.items {
            if item.title == title {
                menu.performActionForItem(at: menu.index(of: item))
                return true
            }
            if let sub = item.submenu, performMenuItem(titled: title, in: sub) { return true }
        }
        return false
    }
}

/// Bounded, same-process accessibility audit + press. Reads the app's OWN AX tree
/// (no cross-process TCC), so it must run OFF the main thread — AX posts its
/// request to the main runloop and blocks the caller until serviced.
enum PrismDebugAX {
    /// Roles that a user is expected to be able to operate (and therefore must be
    /// named + reasonably sized + on-screen).
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXTextField", "AXTextArea", "AXSlider", "AXComboBox", "AXIncrementor",
        "AXLink", "AXTabButton", "AXDisclosureTriangle", "AXStepper",
    ]

    struct Node: Codable {
        let role: String
        let subrole: String?
        let label: String?
        let identifier: String?
        let x: Double, y: Double, w: Double, h: Double
        let enabled: Bool
        let interactive: Bool
    }
    struct Violation: Codable {
        let kind: String          // "no-name" | "small-target" | "offscreen"
        let role: String
        let identifier: String?
        let label: String?
        let detail: String
    }
    struct Report: Codable {
        let state: String
        let elementCount: Int
        let interactiveCount: Int
        let violations: [Violation]
        let elements: [Node]
    }

    // MARK: attribute helpers

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
    private static func boolValue(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.boolValue
    }
    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }
    private static func frame(_ el: AXUIElement) -> CGRect? {
        var fv: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &fv) == .success, let fv {
            var rect = CGRect.zero
            if AXValueGetValue(fv as! AXValue, .cgRect, &rect) { return rect }
        }
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success, let pv,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success, let sv
        else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private static func label(_ el: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, "AXHelp"] {
            if let s = string(el, attr), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return nil
    }

    // MARK: walk

    /// Depth-first walk of every AXWindow owned by this process. Bounded so a
    /// pathological tree can't hang the audit.
    private static func walk(app: AXUIElement) -> (nodes: [Node], windowUnion: CGRect) {
        var nodes: [Node] = []
        var union = CGRect.null
        var count = 0
        let maxNodes = 6000, maxDepth = 60

        func visit(_ el: AXUIElement, depth: Int) {
            guard count < maxNodes, depth < maxDepth else { return }
            count += 1
            let role = string(el, kAXRoleAttribute as String) ?? "AXUnknown"
            let ident = { () -> String? in
                let s = string(el, kAXIdentifierAttribute as String)
                return (s?.isEmpty ?? true) ? nil : s
            }()
            let lbl = label(el)
            let rect = frame(el) ?? .zero
            let interactive = interactiveRoles.contains(role)
            nodes.append(Node(role: role, subrole: string(el, kAXSubroleAttribute as String),
                              label: lbl, identifier: ident,
                              x: rect.origin.x, y: rect.origin.y, w: rect.width, h: rect.height,
                              enabled: boolValue(el, kAXEnabledAttribute as String) ?? true,
                              interactive: interactive))
            for child in children(el) { visit(child, depth: depth + 1) }
        }

        var wv: CFTypeRef?
        let windows: [AXUIElement]
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wv) == .success,
           let arr = wv as? [AXUIElement] { windows = arr } else { windows = [] }
        for win in windows {
            if let wf = frame(win) { union = union.union(wf) }
            visit(win, depth: 0)
        }
        return (nodes, union)
    }

    /// Screen frame (top-left origin) of the element whose AXIdentifier ==
    /// `identifier`, via the MIG API (which builds SwiftUI's a11y tree). Call
    /// off-main — same-process AX round-trips the main runloop.
    static func screenFrame(ofIdentifier identifier: String) -> CGRect? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        func find(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 60 else { return nil }
            if string(el, kAXIdentifierAttribute as String) == identifier { return el }
            for c in children(el) { if let hit = find(c, depth: depth + 1) { return hit } }
            return nil
        }
        var wv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wv) == .success,
              let windows = wv as? [AXUIElement] else { return nil }
        for win in windows { if let hit = find(win, depth: 0) { return frame(hit) } }
        return nil
    }

    /// Audit the tree per the three rules. Returns violations for interactive
    /// controls only (decorative/static elements are exempt).
    private static func audit(_ nodes: [Node], windowUnion: CGRect) -> [Violation] {
        var out: [Violation] = []
        for n in nodes where n.interactive {
            let named = (n.label?.isEmpty == false) || (n.identifier?.isEmpty == false)
            if !named {
                out.append(Violation(kind: "no-name", role: n.role, identifier: n.identifier,
                                     label: n.label, detail: "interactive element has neither AX label nor identifier"))
            }
            let size = CGRect(x: n.x, y: n.y, width: n.w, height: n.h)
            if n.w <= 0 || n.h <= 0 || (!windowUnion.isNull && !windowUnion.intersects(size)) {
                out.append(Violation(kind: "offscreen", role: n.role, identifier: n.identifier,
                                     label: n.label,
                                     detail: String(format: "frame (%.0f,%.0f %.0fx%.0f) is zero-size or off the window", n.x, n.y, n.w, n.h)))
            } else if n.w < 20 || n.h < 20 {
                out.append(Violation(kind: "small-target", role: n.role, identifier: n.identifier,
                                     label: n.label,
                                     detail: String(format: "hit target %.0fx%.0f < 20pt", n.w, n.h)))
            }
        }
        return out
    }

    /// PRISM_DEBUG_AX_DUMP: after `delay`, walk + audit off-main, write the JSON
    /// report to `path`, log a one-line summary, then quit through the REAL quit
    /// path. `state` is only a label for the report.
    @MainActor
    static func scheduleDump(to path: String, state: String, delay: Double) {
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            let pid = ProcessInfo.processInfo.processIdentifier
            DispatchQueue.global(qos: .userInitiated).async {
                let app = AXUIElementCreateApplication(pid)
                let (nodes, union) = walk(app: app)
                let violations = audit(nodes, windowUnion: union)
                let report = Report(state: state, elementCount: nodes.count,
                                    interactiveCount: nodes.filter(\.interactive).count,
                                    violations: violations, elements: nodes)
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? enc.encode(report) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                NSLog("PRISM_DEBUG_AX_DUMP[\(state)]: \(nodes.count) elements, \(report.interactiveCount) interactive, \(violations.count) violation(s) → \(path)")
                // Quit through a runloop Timer, NOT a main-queue drain: calling
                // terminate() from inside DispatchQueue.main.async deadlocks the
                // .terminateLater nested loop (same rule the screenshot hook obeys).
                DispatchQueue.main.async {
                    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
    }

}

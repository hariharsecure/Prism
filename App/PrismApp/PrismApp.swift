import AppKit
import Combine
import SwiftUI

/// Owns the engine and clean termination (C23): every quit path — the
/// "Quit Prism" menu item, Cmd-Q, logout — routes through
/// `applicationShouldTerminate`, which delays termination until
/// `AppEngine.shutdown()` (including finalizing an in-progress recording)
/// has completed, then replies to AppKit to finish terminating.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let engine = AppEngine()
    /// Owns system-wide hotkeys (Carbon RegisterEventHotKey). Created lazily
    /// after the engine so it can wire actions to it, and started once at launch.
    lazy var hotKeys = HotKeyManager(engine: engine)
    private var shutdownStarted = false
    private var engineWillChange: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The App's Scene body reads `engine` through this delegate; forward
        // the engine's change signal so e.g. the menu-bar icon stays live.
        engineWillChange = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Register any persisted global hotkeys with the OS (fires backgrounded).
        hotKeys.start()

        // Debug-only headless verification hooks (same pattern as
        // PRISM_LINK_STATE_FILE / PRISM_AUTOADD_PEERS; no-ops in normal use):
        //   PRISM_DEBUG_AUTO_RECORD_SECONDS=n → toggle recording on after n s.
        //   PRISM_DEBUG_AUTO_QUIT_SECONDS=n   → NSApp.terminate after n s,
        // exercising the REAL quit path (applicationShouldTerminate →
        // engine.shutdown → recorder finalize) without UI scraping.
        // Timers (runloop sources), NOT DispatchQueue.main.asyncAfter: calling
        // terminate(nil) from inside a main-queue drain deadlocks the
        // .terminateLater nested event loop (it cannot re-enter the main
        // queue, so the MainActor reply Task never runs — verified with a
        // stack sample). A runloop timer fires in the same context as a real
        // menu action, which is exactly the path this hook must emulate.
        let env = ProcessInfo.processInfo.environment
        //   PRISM_DEBUG_STUDIO=1 → flip studio mode on at launch so the dual
        // (preview/program) monitor layout can be screenshotted headlessly (there
        // is no other launch-time state driver for studioMode). View-layer only —
        // this just sets the published flag the UI branches on.
        if env["PRISM_DEBUG_STUDIO"] == "1" {
            engine.studioMode = true
        }
        //   PRISM_DEBUG_UI_STATE=<name> → drive the app into a named UI state (see
        // PrismDebugUIState.allStates) at launch, for the UI-snapshot harness. Uses
        // the real engine mutators + in-window AX presses; no-op without the var.
        if let uiState = env["PRISM_DEBUG_UI_STATE"], !uiState.isEmpty {
            PrismDebugUIState.apply(uiState, engine: engine)
        }
        //   PRISM_DEBUG_AX_DUMP=<file> → after a settle delay, walk THIS window's
        // AX tree → JSON + audit (no-name / <20pt / offscreen interactive), then
        // quit through the real path. Pair with PRISM_DEBUG_UI_STATE to audit a
        // specific state. Same Timer-not-asyncAfter rule as the hooks above.
        if let axFile = env["PRISM_DEBUG_AX_DUMP"], !axFile.isEmpty {
            let delay = env["PRISM_DEBUG_AX_DELAY"].flatMap(Double.init) ?? 2.5
            PrismDebugAX.scheduleDump(to: axFile, state: env["PRISM_DEBUG_UI_STATE"] ?? "default", delay: delay)
        }
        if let seconds = env["PRISM_DEBUG_AUTO_RECORD_SECONDS"].flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.toggleRecording() }
            }
        }
        if let seconds = env["PRISM_DEBUG_AUTO_QUIT_SECONDS"].flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                NSApplication.shared.terminate(nil)
            }
        }
        //   PRISM_DEBUG_SCREENSHOT="dir,delaySeconds" → after the delay, capture
        // a PNG of each of the app's own on-screen windows into `dir` (via
        // `screencapture -l<windowID>`), then terminate through the REAL quit
        // path — same Timer-not-asyncAfter rule as the hooks above.
        if let spec = env["PRISM_DEBUG_SCREENSHOT"] {
            let parts = spec.split(separator: ",", maxSplits: 1).map(String.init)
            let dir = parts.first ?? ""
            let delay = parts.count > 1 ? (Double(parts[1]) ?? 3) : 3
            if !dir.isEmpty {
                Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                    MainActor.assumeIsolated { Self.captureDebugScreenshots(to: dir) }
                }
            }
        }
    }

    /// PRISM_DEBUG_SCREENSHOT: shoot every on-screen window owned by this
    /// process to `directory` as `prism_window<N>.png`, then quit through
    /// `applicationShouldTerminate` (engine shutdown included). Debug-only —
    /// unreachable unless the env hook above is set.
    private static func captureDebugScreenshots(to directory: String) {
        let dirURL = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let windows = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var index = 0
        for info in windows {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == pid,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            // Skip sub-window-sized surfaces (menu-bar extra, status items).
            if let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let w = (bounds["Width"] as? NSNumber)?.doubleValue,
               let h = (bounds["Height"] as? NSNumber)?.doubleValue,
               w < 200 || h < 200 { continue }
            index += 1
            let file = dirURL.appendingPathComponent("prism_window\(index).png").path
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -o: no window shadow, -x: no sound, -l: capture by window id.
            task.arguments = ["-o", "-x", "-l", String(windowID), file]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                NSLog("PRISM_DEBUG_SCREENSHOT: screencapture failed to launch: \(error)")
            }
        }
        NSLog("PRISM_DEBUG_SCREENSHOT: captured \(index) window(s) to \(directory)")
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Re-entrant terminate (e.g. Cmd-Q twice) while shutdown is running:
        // keep waiting for the first shutdown's reply.
        guard !shutdownStarted else { return .terminateLater }
        shutdownStarted = true
        Task { @MainActor in
            await engine.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.engine)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // v2 deliverable 2: open the Multiview monitor (Window menu / ⌥⌘M).
            CommandGroup(after: .windowArrangement) {
                MultiviewMenuCommand()
            }
        }

        // v2 deliverable 2: the Multiview monitor lives in its own window.
        WindowGroup("Multiview", id: MultiviewMenuCommand.windowID) {
            MultiviewWindow()
                .environmentObject(appDelegate.engine)
        }
        .windowResizability(.contentMinSize)

        // Menu bar extra: on-air/record status + record toggle (DESIGN §2.6).
        MenuBarExtra {
            MenuBarStatusView()
                .environmentObject(appDelegate.engine)
        } label: {
            Image(systemName: appDelegate.engine.isRecording ? "record.circle.fill" : "sparkles.tv")
        }

        // Settings window (⌘,): hosts the global-hotkeys binding UI. The app had
        // no formal Settings surface before; this adds one.
        Settings {
            HotKeysSettingsView()
                .environmentObject(appDelegate.engine)
                .environmentObject(appDelegate.hotKeys)
        }
    }
}

/// Window-menu command that opens the Multiview monitor window (v2 deliverable 2).
struct MultiviewMenuCommand: View {
    static let windowID = "multiview"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Multiview Monitor") { openWindow(id: Self.windowID) }
            .keyboardShortcut("m", modifiers: [.command, .option])
    }
}

struct MenuBarStatusView: View {
    @EnvironmentObject private var engine: AppEngine

    var body: some View {
        Group {
            Text(engine.isOnAir ? "Prism — ON AIR" : "Prism — off air")
            if let started = engine.recordStartDate {
                Text("Recording · started \(started.formatted(date: .omitted, time: .standard))")
            }
            Divider()
            Button(engine.isRecording ? "Stop Recording" : "Start Recording") {
                engine.toggleRecording()
            }
            if engine.lastRecordingURL != nil {
                Button("Reveal Last Recording") { engine.revealLastRecording() }
            }
            Divider()
            // Routes through AppDelegate.applicationShouldTerminate → engine.shutdown().
            Button("Quit Prism") { NSApplication.shared.terminate(nil) }
        }
    }
}

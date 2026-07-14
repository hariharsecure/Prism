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
    private var shutdownStarted = false
    private var engineWillChange: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The App's Scene body reads `engine` through this delegate; forward
        // the engine's change signal so e.g. the menu-bar icon stays live.
        engineWillChange = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

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

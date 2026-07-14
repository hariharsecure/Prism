import SwiftUI

@main
struct PrismCameraApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            // Debug/verification hook: `PRISM_CAMERA_SYNTHETIC=1` swaps the
            // camera viewfinder for a headless synthetic-frame streamer so the
            // PrismLink transport can be verified end-to-end in the iOS
            // Simulator (which has no camera). Any normal launch (no env var)
            // is completely unaffected and shows the real camera UI.
            if SyntheticLaunch.isEnabled {
                SyntheticStreamerView()
            } else {
                CameraScreen()
            }
        }
    }
}

/// Parses the synthetic-mode launch environment (see `SyntheticStreamer`).
enum SyntheticLaunch {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var isEnabled: Bool { env["PRISM_CAMERA_SYNTHETIC"] == "1" }

    static func makeOptions() -> SyntheticStreamer.Options {
        let e = env
        return SyntheticStreamer.Options(
            deviceName: e["PRISM_CAMERA_NAME"] ?? "iOS Simulator (synthetic)",
            pairingCode: e["PRISM_CAMERA_CODE"] ?? "",
            host: e["PRISM_CAMERA_HOST"],
            port: e["PRISM_CAMERA_PORT"].flatMap(UInt16.init),
            width: e["PRISM_CAMERA_WIDTH"].flatMap(Int.init) ?? 1280,
            height: e["PRISM_CAMERA_HEIGHT"].flatMap(Int.init) ?? 720,
            fps: e["PRISM_CAMERA_FPS"].flatMap(Int.init) ?? 30)
    }
}

/// Minimal status surface for synthetic mode — the real proof is the Mac-side
/// link-server transcript; this just keeps the app foregrounded and streaming.
struct SyntheticStreamerView: View {
    @State private var streamer = SyntheticStreamer(options: SyntheticLaunch.makeOptions())

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 44))
            Text("Prism Camera — Synthetic Mode")
                .font(.headline)
            Text("Streaming synthetic HEVC over QUIC to verify the transport. Check the Mac-side link-server output for peer-connect + frames.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            streamer.start()
        }
    }
}

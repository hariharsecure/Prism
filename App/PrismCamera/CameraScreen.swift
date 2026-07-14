import SwiftUI

/// Prism Camera main screen: full-bleed viewfinder, tally banner, camera
/// controls, and the discovered-Macs connect list.
struct CameraScreen: View {
    @StateObject private var model = CameraAppModel()

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                if model.onAir {
                    tallyBanner
                }
                Spacer()
                controls
            }
        }
        .ignoresSafeArea(edges: model.onAir ? [] : .top)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // keep-awake on set
            model.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Viewfinder / streaming card

    @ViewBuilder
    private var background: some View {
        if model.isStreaming || model.isBusy {
            // The streamer owns the camera while connected; show the on-air card.
            VStack(spacing: 14) {
                Image(systemName: "video.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(model.onAir ? .red : .secondary)
                Text(model.statusText)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        } else if model.cameraDenied {
            VStack(spacing: 12) {
                Image(systemName: "video.slash")
                    .font(.system(size: 44))
                Text("Camera access is off.\nEnable it in Settings → Privacy → Camera.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        } else {
            CameraPreviewView(session: model.previewSession)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }

    // MARK: Tally

    private var tallyBanner: some View {
        Label("ON AIR", systemImage: "dot.radiowaves.left.and.right")
            .font(.system(size: 28, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.red)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 28) {
                Button {
                    model.toggleTorch()
                } label: {
                    Image(systemName: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(model.lens == .front)

                Button {
                    model.toggleLens()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .foregroundStyle(.white)

            connectPanel
        }
        .padding(.bottom, 24)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var connectPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isStreaming || model.isBusy {
                HStack {
                    Text(model.statusText)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Button(role: .destructive) {
                        model.disconnect()
                    } label: {
                        Text("Stop")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } else {
                Text("Pairing code (shown in Prism on your Mac)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("ABCD-2345", text: $model.pairingCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

                Text(model.servers.isEmpty
                     ? "Looking for Prism on your network…"
                     : (model.pairingCodeLooksComplete
                        ? "Connect to a Mac"
                        : "Enter the 8-character code to connect"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(model.servers) { item in
                    Button {
                        model.connect(item)
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Text("Connect")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.pairingCodeLooksComplete)
                    .opacity(model.pairingCodeLooksComplete ? 1 : 0.4)
                }

                if case .failed = model.state {
                    Text(model.statusText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

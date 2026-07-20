import PrismOutput
import SwiftUI

/// Multi-destination restream editor (deliverable B). Lives in the transport
/// bar's streaming popover: add/remove/enable RTMP + SRT destinations (each with
/// name + protocol + URL + key/streamid), persisted to Application Support. While
/// live, shows per-destination connection state + bytes out from the broadcaster.
struct DestinationsEditor: View {
    @EnvironmentObject private var engine: AppEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Extra destinations").font(.subheadline.weight(.semibold))
                Text("optional").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    engine.addDestination(Destination(name: "New destination",
                                                      proto: .rtmp, url: "", key: "",
                                                      enabled: true))
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("destinations.add.button")
                .controlSize(.small)
                .help("Add another platform to stream to at the same time")
            }

            if engine.destinations.isEmpty {
                Text("The primary above is enough to go live. Add RTMP or SRT targets here only if you want to stream to several platforms (e.g. YouTube + Twitch) at once.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(engine.destinations) { dest in
                    DestinationRow(destination: dest)
                }
            }
        }
    }
}

/// One editable destination row. Fields write back through the engine (which
/// persists); the enable toggle also brings the destination up/down live.
private struct DestinationRow: View {
    @EnvironmentObject private var engine: AppEngine
    let destination: Destination

    /// Live copy from the engine (falls back to the passed-in value mid-delete).
    private var current: Destination {
        engine.destinations.first { $0.id == destination.id } ?? destination
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { current.enabled },
                set: { engine.setDestinationEnabled($0, id: destination.id) })
    }

    private func fieldBinding(_ keyPath: WritableKeyPath<Destination, String>) -> Binding<String> {
        Binding(get: { current[keyPath: keyPath] },
                set: { var d = current; d[keyPath: keyPath] = $0; engine.updateDestination(d) })
    }

    private var protoBinding: Binding<Destination.Proto> {
        Binding(get: { current.proto },
                set: { var d = current; d.proto = $0; engine.updateDestination(d) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle("", isOn: enabledBinding)
                    .accessibilityIdentifier("destinations.row.enabled.toggle")
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Include this destination when you Go Live")
                TextField("Name", text: fieldBinding(\.name))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("destinations.row.name.field")
                    .frame(width: 120)
                Picker("", selection: protoBinding) {
                    Text("RTMP").tag(Destination.Proto.rtmp)
                    Text("SRT").tag(Destination.Proto.srt)
                }
                .accessibilityIdentifier("destinations.row.proto.picker")
                .labelsHidden()
                .frame(width: 74)
                .disabled(engine.isStreaming)
                Spacer()
                Button {
                    engine.removeDestination(destination.id)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .accessibilityIdentifier("destinations.row.remove")
                .buttonStyle(.plain)
                .help("Remove destination")
            }
            HStack(spacing: 6) {
                TextField(current.proto == .srt ? "srt://host:port?…" : "rtmp://host/app",
                          text: fieldBinding(\.url))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("destinations.row.url.field")
                    .disabled(engine.isStreaming)
                // Codex #8: the key/streamid is a secret — mask it (and it is
                // stored in the Keychain, not the plaintext JSON).
                SecureField(current.proto == .srt ? "streamid" : "stream key",
                            text: fieldBinding(\.key))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("destinations.row.key.field")
                    .frame(width: 110)
                    .disabled(engine.isStreaming)
            }
            if let stats = engine.destinationStats[destination.id] {
                Text(Self.statusLine(stats))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Self.tint(stats.state))
            } else if engine.isStreaming, current.enabled {
                Text("connecting…").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private static func statusLine(_ s: StreamDestinationStats) -> String {
        "\(describe(s.state)) · \(TransportBar.bitrateString(s.bytesOutPerSecond * 8)) · \(s.videoFramesAppended) vf"
            + (s.appendsDropped > 0 ? " · \(s.appendsDropped) dropped" : "")
    }

    private static func describe(_ state: StreamConnectionState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .publishing: return "live"
        case .reconnecting(let a): return "reconnecting (\(a))"
        case .closed: return "closed"
        case .failed(let r): return "failed: \(r)"
        }
    }

    private static func tint(_ state: StreamConnectionState) -> Color {
        switch state {
        case .publishing: return .green
        case .failed: return .red
        case .reconnecting: return .orange
        default: return .secondary
        }
    }
}

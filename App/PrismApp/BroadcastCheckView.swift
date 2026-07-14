import SwiftUI

/// Preflight "Broadcast Check" sheet (deliverable 2): runs the checklist and
/// shows each check's pass/warn/fail with a message. Reached from the "Broadcast
/// Check" button in the transport bar.
struct BroadcastCheckView: View {
    @EnvironmentObject private var engine: AppEngine
    @Environment(\.dismiss) private var dismiss
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Broadcast Check").font(.title2.bold())
                Spacer()
                if let report = engine.lastBroadcastReport {
                    overallBadge(report.overall)
                }
            }

            Text("Preflight checks before you go live.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            if let report = engine.lastBroadcastReport {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.results) { result in
                        row(result)
                    }
                }
                Text("Checked \(report.generatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Run the check to see results.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }

            Divider()

            HStack {
                Button {
                    running = true
                    Task {
                        await engine.runBroadcastCheck()
                        running = false
                    }
                } label: {
                    if running {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                    } else {
                        Label("Run Broadcast Check", systemImage: "checklist")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)

                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            // Auto-run on first open so the sheet is never empty.
            if engine.lastBroadcastReport == nil {
                running = true
                await engine.runBroadcastCheck()
                running = false
            }
        }
    }

    private func row(_ result: CheckResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(result.status))
                .foregroundStyle(color(result.status))
                .font(.body.weight(.semibold))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.body.weight(.medium))
                Text(result.message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func overallBadge(_ status: CheckStatus) -> some View {
        Text(label(status).uppercased())
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color(status), in: Capsule())
            .foregroundStyle(.white)
    }

    private func icon(_ status: CheckStatus) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private func color(_ status: CheckStatus) -> Color {
        switch status {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }

    private func label(_ status: CheckStatus) -> String {
        switch status {
        case .pass: return "Ready"
        case .warn: return "Warnings"
        case .fail: return "Not ready"
        }
    }
}

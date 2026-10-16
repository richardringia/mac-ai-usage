import SwiftUI
import ServiceManagement

struct ContentView: View {
    @Environment(UsageMonitor.self) private var monitor
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled

    private var problems: String? {
        let lines = [monitor.limits.problem, monitor.limits.claude.problem, monitor.limits.cursor.problem, monitor.sharingProblem].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("AI Usage").font(.headline)
            VStack(spacing: 8) {
                Text("Claude Code").font(.subheadline)
                HStack(alignment: .top, spacing: 20) {
                    ForEach(monitor.limits.claude.windows) { LimitGauge(window: $0) }
                }
            }
            VStack(spacing: 8) {
                Text("Cursor").font(.subheadline)
                HStack(alignment: .top, spacing: 20) {
                    ForEach(monitor.limits.cursor.windows) { LimitGauge(window: $0) }
                }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                UpdateLabel(limits: monitor.limits, date: context.date)
            }
            if let problems {
                Text(problems).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            } else {
                if monitor.limits.window(UsageWindow.fiveHours).remaining == nil {
                    Text("Claude Code has not reported a 5-hour limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if monitor.limits.window(UsageWindow.auto).remaining == nil {
                    Text("Cursor has not reported Auto usage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(monitor.isRefreshing ? "Refreshing…" : "Refresh") {
                Task { await monitor.refresh() }
            }
            .disabled(monitor.isRefreshing)
            Text("Keep this app running to update the desktop widgets.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Toggle("Start at login", isOn: $startAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: startAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        startAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .font(.caption)
        }
        .padding(24)
        .frame(width: 360)
    }
}

#Preview { ContentView().environment(UsageMonitor()) }

import Foundation
import SwiftUI
import OSLog
import Darwin

nonisolated enum UsageWindow {
    static let fiveHours = "5 hours"
    static let week = "Week"
    static let auto = "Auto"
    static let api = "API"
}

nonisolated struct LimitWindow: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let remaining: Double?
    let resetsAt: Date?
    let note: String?
    var id: String { name }
}

nonisolated struct Side: Codable, Equatable, Sendable {
    var windows: [LimitWindow]
    var problem: String?

    func merging(_ update: Side) -> Side {
        guard update.problem == nil else {
            var kept = self
            kept.problem = update.problem
            return kept
        }
        return update
    }
}

nonisolated struct Limits: Codable, Equatable, Sendable {
    var claude: Side
    var cursor: Side
    var updatedAt: Date?
    var problem: String?

    var windows: [LimitWindow] { claude.windows + cursor.windows }

    static let empty = Limits(
        claude: Side(windows: [
            .init(name: UsageWindow.fiveHours, remaining: nil, resetsAt: nil, note: nil),
            .init(name: UsageWindow.week, remaining: nil, resetsAt: nil, note: nil)
        ], problem: nil),
        cursor: Side(windows: [
            .init(name: UsageWindow.auto, remaining: nil, resetsAt: nil, note: nil),
            .init(name: UsageWindow.api, remaining: nil, resetsAt: nil, note: nil)
        ], problem: nil)
    )

    func window(_ name: String) -> LimitWindow {
        windows.first { $0.name == name } ?? .init(name: name, remaining: nil, resetsAt: nil, note: nil)
    }

    func isStale(at date: Date, side: Side? = nil) -> Bool {
        guard let updatedAt else { return false }
        let flagged: String?
        let relevant: [LimitWindow]
        if let side {
            flagged = side.problem
            relevant = side.windows
        } else {
            flagged = claude.problem ?? cursor.problem
            relevant = windows
        }
        return problem != nil || flagged != nil || date.timeIntervalSince(updatedAt) >= 600
            || relevant.contains { $0.resetsAt.map { $0 <= date } ?? false }
    }

    /// Keeps a side's last numbers when that side's refresh failed.
    func merged(with update: Limits) -> Limits {
        var result = self
        result.claude = claude.merging(update.claude)
        result.cursor = cursor.merging(update.cursor)
        if update.claude.problem == nil || update.cursor.problem == nil {
            result.updatedAt = update.updatedAt
            result.problem = nil
        }
        return result
    }
}

/// Shared by the app and widget so their on-disk format cannot drift.
nonisolated enum WidgetSnapshot {
    // ponytail: local ad-hoc build; use a registered App Group when distributing a developer-signed app.
    // The widget entitlement grants read-only access to this single snapshot, not the directory.
    static var fileURL: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appending(path: "Library/Application Support/com.richardringia.AiUsage/usage.json")
    }

    static func load(from url: URL? = fileURL) -> Limits {
        do {
            guard let url else { throw CocoaError(.fileReadNoPermission) }
            let limits = try JSONDecoder().decode(Limits.self, from: Data(contentsOf: url))
            Logger(subsystem: "com.richardringia.AiUsage", category: "Snapshot").notice("Snapshot loaded by \(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public); claude \(limits.window(UsageWindow.fiveHours).remaining ?? -1, privacy: .public); cursor auto \(limits.window(UsageWindow.auto).remaining ?? -1, privacy: .public)")
            return limits
        } catch {
            Logger(subsystem: "com.richardringia.AiUsage", category: "Snapshot").error("Snapshot read failed: \(String(reflecting: error), privacy: .public)")
            var limits = Limits.empty
            limits.problem = "Cannot read widget data. Open AI Usage and refresh. (\((error as NSError).code))"
            return limits
        }
    }

    static func write(_ limits: Limits) throws {
        guard let url = fileURL else {
            throw NSError(domain: "AiUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Widget sharing is unavailable. Check the snapshot path."])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(limits).write(to: url, options: .atomic)
    }
}

struct LimitGauge: View {
    let window: LimitWindow

    private var tint: Color {
        guard let value = window.remaining else { return .secondary }
        return value <= 10 ? .red : value <= 30 ? .orange : .accentColor
    }

    var body: some View {
        VStack(spacing: 4) {
            Gauge(value: window.remaining ?? 0, in: 0...100) {
                Text(window.name)
            } currentValueLabel: { value }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(tint)
                .scaleEffect(1.25)
                .frame(height: 70)
            Text(window.name).font(.caption)
            if window.remaining == nil { Text("Unavailable").font(.caption2).foregroundStyle(.secondary) }
            if let reset = window.resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            if let note = window.note {
                Text(note)
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var value: some View {
        Group {
            if let remaining = window.remaining {
                Text(remaining / 100, format: .percent.precision(.fractionLength(0)))
            } else {
                Text("—")
                    .accessibilityLabel("Unavailable")
            }
        }
        .font(.caption.weight(.semibold).monospacedDigit())
    }
}

struct UpdateLabel: View {
    let limits: Limits
    let date: Date
    var side: Side? = nil

    var body: some View {
        let stale = limits.isStale(at: date, side: side)
        Group {
            if let updated = limits.updatedAt {
                Text("\(stale ? "Stale · " : "")Updated \(updated, style: .time)")
            } else {
                Text("Open AI Usage")
            }
        }
        .font(.caption2)
        .foregroundStyle(stale ? Color.orange : .secondary)
    }
}

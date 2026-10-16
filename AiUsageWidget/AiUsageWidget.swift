import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let limits: Limits
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, limits: Limits(
            claude: Side(windows: [
                .init(name: UsageWindow.fiveHours, remaining: 62, resetsAt: .now.addingTimeInterval(7200), note: nil),
                .init(name: UsageWindow.week, remaining: 70, resetsAt: .now.addingTimeInterval(518400), note: "All models 80% left")
            ], problem: nil),
            cursor: Side(windows: [
                .init(name: UsageWindow.auto, remaining: 92, resetsAt: .now.addingTimeInterval(1_200_000), note: nil),
                .init(name: UsageWindow.api, remaining: 100, resetsAt: .now.addingTimeInterval(1_200_000), note: nil)
            ], problem: nil),
            updatedAt: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Entry(date: .now, limits: WidgetSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let limits = WidgetSnapshot.load()
        let now = Date.now
        var dates = [now, now.addingTimeInterval(600)]
        if let updated = limits.updatedAt, updated.addingTimeInterval(600) > now { dates.append(updated.addingTimeInterval(600)) }
        dates += limits.windows.compactMap(\.resetsAt).filter { $0 > now && $0 <= now.addingTimeInterval(600) }
        completion(Timeline(entries: dates.sorted().map { Entry(date: $0, limits: limits) },
                            policy: .after(now.addingTimeInterval(300))))
    }
}

struct LimitsWidgetView: View {
    let title: String
    let windowName: String
    let entry: Entry

    private var side: Side {
        entry.limits.cursor.windows.contains { $0.name == windowName } ? entry.limits.cursor : entry.limits.claude
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.caption.weight(.semibold))
            LimitGauge(window: entry.limits.window(windowName))
            UpdateLabel(limits: entry.limits, date: entry.date, side: side)
            if entry.limits.updatedAt == nil, let problem = entry.limits.problem ?? side.problem {
                Text(problem).font(.system(size: 9)).lineLimit(2)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ClaudeFiveHourWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeLimits", provider: Provider()) { entry in
            LimitsWidgetView(title: "Claude 5h", windowName: UsageWindow.fiveHours, entry: entry)
        }
        .configurationDisplayName("Claude 5h")
        .description("Your remaining Claude Code 5-hour allowance.")
        .supportedFamilies([.systemSmall])
    }
}

struct ClaudeWeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeWeekly", provider: Provider()) { entry in
            LimitsWidgetView(title: "Claude week", windowName: UsageWindow.week, entry: entry)
        }
        .configurationDisplayName("Claude week")
        .description("Your remaining Claude Code weekly allowance.")
        .supportedFamilies([.systemSmall])
    }
}

struct CursorUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CursorTotal", provider: Provider()) { entry in
            LimitsWidgetView(title: "Cursor Auto", windowName: UsageWindow.auto, entry: entry)
        }
        .configurationDisplayName("Cursor Auto")
        .description("Your remaining Cursor Auto allowance.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct AiUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeFiveHourWidget()
        ClaudeWeekWidget()
        CursorUsageWidget()
    }
}

#Preview(as: .systemSmall) { ClaudeFiveHourWidget() } timeline: {
    Entry(date: .now, limits: .empty)
}

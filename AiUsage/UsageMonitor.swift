import Foundation
import Observation
import WidgetKit

@Observable @MainActor
final class UsageMonitor {
    private(set) var limits = WidgetSnapshot.load()
    private(set) var isRefreshing = false
    private(set) var sharingProblem: String?
    private var task: Task<Void, Never>?

    var menuTitle: String {
        "CC \(percent(UsageWindow.fiveHours, in: limits.claude))  C \(percent(UsageWindow.auto, in: limits.cursor))"
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        limits = limits.merged(with: await UsageFetcher.fetch())
        do {
            try WidgetSnapshot.write(limits)
            sharingProblem = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch { sharingProblem = error.localizedDescription }
    }

    private func percent(_ name: String, in side: Side) -> String {
        guard let value = side.windows.first(where: { $0.name == name })?.remaining else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    isolated deinit { task?.cancel() }
}

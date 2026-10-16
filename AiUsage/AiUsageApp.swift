import SwiftUI

@main
struct AiUsageApp: App {
    @State private var monitor: UsageMonitor

    init() {
        // Background app: nothing is on screen until the menu item is clicked, so start monitoring here.
        let m = UsageMonitor()
        m.start()
        _monitor = State(initialValue: m)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(monitor)
        } label: {
            Text(monitor.menuTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

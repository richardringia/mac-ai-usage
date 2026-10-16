import Foundation
import Testing
@testable import AiUsage

@Suite struct UsageTests {
    @Test func claudePrefersOpusWeekAndKeepsAllModelsNote() throws {
        let data = Data(#"{"five_hour":{"utilization":33,"resets_at":"2026-04-11T07:00:00.528743+00:00"},"seven_day":{"utilization":13,"resets_at":"2026-04-17T00:59:59Z"},"seven_day_opus":{"utilization":12,"resets_at":"2026-04-17T01:00:00Z"}}"#.utf8)
        let side = try LimitsReader.parseClaude(data)
        #expect(side.windows.map(\.name) == ["5 hours", "Week"])
        #expect(side.windows.map(\.remaining) == [67, 88])
        #expect(side.windows[1].note == "All models 87% left")
        let reset = try #require(side.windows[0].resetsAt)
        #expect(reset == LimitsReader.parseReset("2026-04-11T07:00:00.528743+00:00"))
    }

    @Test func claudeFallsBackWhenOpusWeekIsNull() throws {
        let data = Data(#"{"five_hour":{"utilization":-5,"resets_at":"not-a-date"},"seven_day":{"utilization":110,"resets_at":"2026-04-17T00:59:59Z"},"seven_day_opus":null}"#.utf8)
        let side = try LimitsReader.parseClaude(data)
        #expect(side.windows.map(\.remaining) == [100, 0])
        #expect(side.windows[1].note == nil)
        #expect(side.windows[0].resetsAt == nil)
        #expect(throws: (any Error).self) { try LimitsReader.parseClaude(Data("[]".utf8)) }
    }

    @Test func claudeReadsStatusLinePercentages() throws {
        let data = Data(#"{"rate_limits":{"five_hour":{"used_percentage":3,"resets_at":1788615600},"seven_day":{"used_percentage":0,"resets_at":1789149600}}}"#.utf8)
        let side = try LimitsReader.parseClaude(data)
        #expect(side.windows.map(\.remaining) == [97, 100])
        #expect(side.windows[0].resetsAt == Date(timeIntervalSince1970: 1788615600))
        #expect(side.windows[1].note == nil)
    }

    @Test func cursorUsesUsageMetersNotExhaustedDollars() throws {
        let data = Data(#"{"billingCycleEnd":"1792673013000","planUsage":{"remaining":0,"limit":2000,"includedSpend":2000,"totalPercentUsed":6.87,"autoPercentUsed":7.56,"apiPercentUsed":0}}"#.utf8)
        let side = try LimitsReader.parseCursor(data)
        #expect(side.windows.map(\.name) == ["Auto", "API"])
        #expect(abs((side.windows[0].remaining ?? -1) - 92.44) < 0.01)
        #expect(side.windows[1].remaining == 100)
    }

    @Test func cursorUsesRemainingCentsAndDerivesWhenOmitted() throws {
        let present = try LimitsReader.parseCursor(Data(#"{"billingCycleEnd":"1771077734000","planUsage":{"remaining":16778,"limit":40000,"includedSpend":0}}"#.utf8))
        let presentExpected: Double = 16778.0 / 40000 * 100
        #expect(present.windows[0].remaining == presentExpected)
        #expect(present.windows[0].note == "$167.78 of $400 left")
        #expect(present.windows[0].resetsAt == Date(timeIntervalSince1970: 1771077734))
        let omitted = try LimitsReader.parseCursor(Data(#"{"billingCycleEnd":1771077734000,"planUsage":{"includedSpend":23222,"limit":"40000"}}"#.utf8))
        let omittedExpected: Double = (40000.0 - 23222) / 40000 * 100
        #expect(omitted.windows[0].remaining == omittedExpected)
        #expect(throws: (any Error).self) { try LimitsReader.parseCursor(Data(#"{}"#.utf8)) }
    }

    @Test func failedSideKeepsPreviousNumbers() {
        var previous = Limits.empty
        previous.updatedAt = Date(timeIntervalSince1970: 50)
        previous.claude.windows[0] = .init(name: "5 hours", remaining: 80, resetsAt: nil, note: nil)
        var update = Limits.empty
        update.updatedAt = Date(timeIntervalSince1970: 100)
        update.claude.problem = "Open Claude Code to refresh usage."
        update.cursor.windows[0] = .init(name: "Total", remaining: 41, resetsAt: nil, note: "$10 of $20 left")
        let merged = previous.merged(with: update)
        #expect(merged.window("5 hours").remaining == 80)
        #expect(merged.window("Total").remaining == 41)
        #expect(merged.claude.problem == "Open Claude Code to refresh usage.")
        #expect(merged.cursor.problem == nil)
        #expect(merged.updatedAt == update.updatedAt)
        #expect(!merged.isStale(at: update.updatedAt!, side: merged.cursor))
        #expect(merged.isStale(at: update.updatedAt!, side: merged.claude))
        update.cursor.problem = "Open Cursor and sign in."
        let both = previous.merged(with: update)
        #expect(both.updatedAt == previous.updatedAt)
        #expect(both.window("Total").remaining == nil)
    }

    @Test func staleOnFailureAgeOrReset() {
        let now = Date.now
        var limits = Limits.empty
        limits.updatedAt = now
        #expect(!limits.isStale(at: now.addingTimeInterval(599)))
        #expect(limits.isStale(at: now.addingTimeInterval(600)))
        limits.problem = "Offline"
        #expect(limits.isStale(at: now))
        limits.problem = nil
        limits.claude.windows[1] = .init(name: "Week", remaining: 20, resetsAt: now, note: nil)
        #expect(limits.isStale(at: now))
        #expect(limits.window("Week").remaining == 20)
    }

    @Test func readsStoredLoginsWithoutPrintingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try UsageFetcher.cursorToken(keychainToken: "cursor-token") == "cursor-token")

        let database = directory.appending(path: "state.vscdb")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        create.arguments = [database.path, "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'test-token');"]
        try create.run()
        create.waitUntilExit()
        #expect(create.terminationStatus == 0)
        let token = try UsageFetcher.cursorToken(database: database)
        #expect(token == "test-token")
        #expect((try? UsageFetcher.cursorToken(database: directory.appending(path: "missing.db"))) == nil)
    }

    @Test func statusLineUsesOfficialHookAndLeavesOtherHooksAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "claude-statusline.py")
        let settings = directory.appending(path: "settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: settings)
        try UsageFetcher.installStatusLine(settings: settings, script: script)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        #expect(saved?["model"] as? String == "opus")
        let command = ((saved?["statusLine"] as? [String: Any])?["command"] as? String) ?? ""
        #expect(command.contains("claude-statusline.py"))
        let other = directory.appending(path: "other.json")
        try Data(#"{"statusLine":{"type":"command","command":"my-statusline"}}"#.utf8).write(to: other)
        try UsageFetcher.installStatusLine(settings: other, script: script)
        let kept = try JSONSerialization.jsonObject(with: Data(contentsOf: other)) as? [String: Any]
        #expect(((kept?["statusLine"] as? [String: Any])?["command"] as? String) == "my-statusline")
    }

    @Test func snapshotKeepsEveryWindow() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WidgetSnapshot.load(from: url).problem != nil)
        try Data("invalid".utf8).write(to: url)
        #expect(WidgetSnapshot.load(from: url).problem != nil)
        let limits = Limits(
            claude: Side(windows: [
                .init(name: "5 hours", remaining: 62, resetsAt: nil, note: nil),
                .init(name: "Week", remaining: 88, resetsAt: nil, note: "All models 87% left")
            ], problem: nil),
            cursor: Side(windows: [
                .init(name: "Total", remaining: 41, resetsAt: nil, note: "$168 of $400 left")
            ], problem: nil),
            updatedAt: .now)
        try JSONEncoder().encode(limits).write(to: url)
        let loaded = WidgetSnapshot.load(from: url)
        #expect(loaded.windows.map(\.remaining) == [62, 88, 41])
        #expect(loaded.problem == nil)
        #expect(loaded == limits)
        #expect(WidgetSnapshot.fileURL?.lastPathComponent == "usage.json")
    }
}

import Foundation

nonisolated enum LimitsReader {
    enum ParseError: Error { case invalid }

    static func parseClaude(_ data: Data) throws -> Side {
        let response: ClaudeResponse
        if let wrapped = try? JSONDecoder().decode(ClaudeEnvelope.self, from: data).rateLimits {
            response = wrapped
        } else {
            response = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        }
        let week = response.sevenDayOpus ?? response.sevenDay
        let note: String? = response.sevenDayOpus == nil ? nil : response.sevenDay.flatMap { bucket in
            guard let left = remaining(bucket.used) else { return nil }
            return "All models \(Int(left.rounded()))% left"
        }
        return Side(windows: [
            window(UsageWindow.fiveHours, response.fiveHour, note: nil),
            window(UsageWindow.week, week, note: note)
        ], problem: nil)
    }

    static func parseCursor(_ data: Data) throws -> Side {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = json["planUsage"] as? [String: Any] else { throw ParseError.invalid }
        let resets = date(number(json["billingCycleEnd"]))
        let autoUsed = number(plan["autoPercentUsed"])
        let apiUsed = number(plan["apiPercentUsed"])
        if autoUsed != nil || apiUsed != nil {
            return Side(windows: [
                .init(name: UsageWindow.auto, remaining: autoUsed.flatMap(remaining), resetsAt: resets, note: nil),
                .init(name: UsageWindow.api, remaining: apiUsed.flatMap(remaining), resetsAt: resets, note: nil)
            ], problem: nil)
        }
        guard let limit = number(plan["limit"]), limit > 0 else {
            return Side(windows: [
                .init(name: UsageWindow.auto, remaining: nil, resetsAt: resets, note: nil),
                .init(name: UsageWindow.api, remaining: nil, resetsAt: resets, note: nil)
            ], problem: nil)
        }
        let centsLeft = number(plan["remaining"]) ?? number(plan["includedSpend"]).map { limit - $0 }
        guard let centsLeft, centsLeft.isFinite else { throw ParseError.invalid }
        let left = min(limit, max(0, centsLeft))
        return Side(windows: [
            .init(name: UsageWindow.auto, remaining: left / limit * 100, resetsAt: resets, note: "\(money(left)) of \(money(limit)) left"),
            .init(name: UsageWindow.api, remaining: nil, resetsAt: resets, note: nil)
        ], problem: nil)
    }

    private struct ClaudeEnvelope: Decodable {
        let rateLimits: ClaudeResponse?
        enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }
    }
    private struct ResetValue: Decodable {
        let date: Date?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { date = nil; return }
            if let number = try? container.decode(Double.self) {
                date = number > 0 ? Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number) : nil
                return
            }
            date = (try? container.decode(String.self)).flatMap(LimitsReader.parseReset)
        }
    }
    private struct ClaudeBucket: Decodable {
        let used: Double?
        let resetsAt: Date?
        enum CodingKeys: String, CodingKey {
            case utilization
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            used = try container.decodeIfPresent(Double.self, forKey: .usedPercentage)
                ?? container.decodeIfPresent(Double.self, forKey: .utilization)
            resetsAt = try container.decodeIfPresent(ResetValue.self, forKey: .resetsAt)?.date
        }
    }
    private struct ClaudeResponse: Decodable {
        let fiveHour: ClaudeBucket?
        let sevenDay: ClaudeBucket?
        let sevenDayOpus: ClaudeBucket?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
        }
    }

    private static func window(_ name: String, _ bucket: ClaudeBucket?, note: String?) -> LimitWindow {
        .init(name: name, remaining: bucket.flatMap { remaining($0.used) }, resetsAt: bucket?.resetsAt, note: note)
    }

    private static func remaining(_ used: Double?) -> Double? {
        guard let used, used.isFinite else { return nil }
        return min(100, max(0, 100 - used))
    }

    static func parseReset(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func date(_ raw: Double?) -> Date? {
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
    }

    private static func money(_ cents: Double) -> String {
        let dollars = cents / 100
        if abs(dollars - dollars.rounded()) < 0.001 { return "$\(Int(dollars.rounded()))" }
        return String(format: "$%.2f", dollars)
    }
}

import Foundation
import Darwin
import Security

/// Claude Code reports usage through its own status line. This app never calls Anthropic.
/// Cursor's token stays in memory and is never stored or logged.
/// ponytail: Cursor's period endpoint is undocumented and can change. Fail closed and keep the last good numbers.
nonisolated enum UsageFetcher {
    enum Failure: LocalizedError {
        case claudeUnavailable
        case cursorSignIn, cursorReadFailed, cursorFailed
        var errorDescription: String? {
            switch self {
            case .claudeUnavailable: "Open Claude Code to refresh usage."
            case .cursorSignIn: "Open Cursor and sign in."
            case .cursorReadFailed: "Could not read the Cursor login. Try Refresh."
            case .cursorFailed: "Could not fetch Cursor limits. Check your connection and try Refresh."
            }
        }
    }

    private static let cursorUsage = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    static func fetch() async -> Limits {
        async let claude = claudeSide()
        async let cursor = cursorSide()
        return Limits(claude: await claude, cursor: await cursor, updatedAt: .now, problem: nil)
    }

    private static func claudeSide() async -> Side {
        do {
            try installStatusLine()
            guard let url = claudeRateLimitsURL, let data = try? Data(contentsOf: url) else { throw Failure.claudeUnavailable }
            return try LimitsReader.parseClaude(data)
        } catch let error as Failure {
            return failed(Limits.empty.claude, error)
        } catch {
            return failed(Limits.empty.claude, .claudeUnavailable)
        }
    }

    private static func cursorSide() async -> Side {
        do {
            let token = try await MainActor.run { try cursorToken() }
            let data = try await send(url: cursorUsage, token: token, body: Data("{}".utf8))
            return try LimitsReader.parseCursor(data)
        } catch let error as Failure {
            return failed(Limits.empty.cursor, error)
        } catch {
            return failed(Limits.empty.cursor, .cursorFailed)
        }
    }

    private static func failed(_ side: Side, _ error: Failure) -> Side {
        var side = side
        side.problem = error.localizedDescription
        return side
    }

    static func cursorToken(database: URL? = nil, keychainToken: String? = nil) throws -> String {
        if let keychainToken, !keychainToken.isEmpty { return keychainToken }
        if database == nil, let token = keychainData(service: "cursor-access-token", account: "cursor-user").flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        guard let database = database ?? home()?.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
              FileManager.default.fileExists(atPath: database.path) else { throw Failure.cursorSignIn }
        guard let encoded = database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { throw Failure.cursorReadFailed }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "file://\(encoded)?mode=ro", ".timeout 1000", "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.cursorReadFailed }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, data.count <= 8192,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, !token.contains("\n") else {
            throw process.terminationStatus == 0 ? Failure.cursorSignIn : Failure.cursorReadFailed
        }
        return token
    }

    /// Official Claude Code status line. It writes only the rate-limit fields Claude already provides. No Anthropic request.
    static func installStatusLine(settings: URL? = nil, script: URL? = nil) throws {
        guard let script = script ?? supportDirectory()?.appending(path: "claude-statusline.py"),
              let settings = settings ?? home()?.appending(path: ".claude/settings.json") else { return }
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try statusLineScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let command = "/usr/bin/python3 \(shellQuote(script.path))"
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settings.path) {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] else { return }
            root = parsed
        }
        if let existing = (root["statusLine"] as? [String: Any])?["command"] as? String {
            if existing == command || !existing.contains("claude-statusline.py") { return }
        }
        root["statusLine"] = ["type": "command", "command": command]
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]).write(to: settings, options: .atomic)
    }

    private static var claudeRateLimitsURL: URL? {
        supportDirectory()?.appending(path: "claude-rate-limits.json")
    }

    private static let statusLineScript = #"""
    import json, os, sys
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    limits = data.get("rate_limits") or {}
    if limits:
        path = os.path.expanduser("~/Library/Application Support/com.richardringia.AiUsage/claude-rate-limits.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as handle:
            json.dump({"rate_limits": limits}, handle)
        os.replace(tmp, path)
    def left(window):
        if not isinstance(window, dict):
            return None
        used = window.get("used_percentage", window.get("utilization"))
        if not isinstance(used, (int, float)):
            return None
        return max(0, min(100, round(100 - used)))
    parts = []
    five = left(limits.get("five_hour"))
    week = left(limits.get("seven_day_opus") or limits.get("seven_day"))
    if five is not None:
        parts.append(f"5h {five}%")
    if week is not None:
        parts.append(f"week {week}%")
    if parts:
        print(" · ".join(parts))
    """#

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func supportDirectory() -> URL? {
        home()?.appending(path: "Library/Application Support/com.richardringia.AiUsage")
    }

    private static func send(url: URL, token: String, body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Session.shared.data(for: request)
        guard data.count <= 1_048_576, let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.cursorFailed }
        if status == 401 || status == 403 { throw Failure.cursorSignIn }
        guard status == 200 else { throw Failure.cursorFailed }
        return data
    }

    private static func keychainData(service: String, account: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func home() -> URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }

    private final class Session: NSObject, URLSessionTaskDelegate {
        private static let delegate = Session()
        static let shared: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }()

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

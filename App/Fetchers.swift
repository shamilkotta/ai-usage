import Foundation
import SQLite3

enum FetchError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
}

private let home = FileManager.default.homeDirectoryForCurrentUser

private func run(_ path: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw FetchError.msg("\(path) exited \(p.terminationStatus)") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func json(_ req: URLRequest) async throws -> [String: Any] {
    var req = req
    req.timeoutInterval = 20
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw FetchError.msg(code == 401 || code == 403 ? "Auth expired – open the app" : "HTTP \(code)") }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.msg("Bad response") }
    return obj
}

private func parseISO(_ s: Any?) -> Date? {
    guard let s = s as? String else { return nil }
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

private func windowLabel(seconds: Double) -> String {
    switch seconds {
    case ..<86_400: return "\(Int(seconds / 3600))h"
    case 604_800: return "Week"
    case 2_500_000...2_700_000: return "Month"
    default: return "\(Int(seconds / 86_400))d"
    }
}

// MARK: Claude (token from Claude Code's keychain entry)

func fetchClaude() async throws -> ProviderUsage {
    let raw = try run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    guard let creds = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
          let oauth = creds["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { throw FetchError.msg("Run `claude` to log in") }

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let d = try await json(req)

    var windows: [UsageWindow] = []
    for (key, label) in [("five_hour", "5h"), ("seven_day", "Week"), ("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
        guard let w = d[key] as? [String: Any], let u = num(w["utilization"]) else { continue }
        windows.append(UsageWindow(label: label, percent: u, resetsAt: parseISO(w["resets_at"])))
    }
    return ProviderUsage(id: "claude", name: "Claude", plan: (oauth["subscriptionType"] as? String)?.capitalized, windows: windows)
}

// MARK: Codex (ChatGPT login from ~/.codex/auth.json)

func fetchCodex() async throws -> ProviderUsage {
    let data = try Data(contentsOf: home.appendingPathComponent(".codex/auth.json"))
    guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = auth["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String else { throw FetchError.msg("Run `codex login`") }

    var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let acct = tokens["account_id"] as? String { req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id") }
    req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
    let d = try await json(req)

    var windows: [UsageWindow] = []
    if let rl = d["rate_limit"] as? [String: Any] {
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl[key] as? [String: Any], let u = num(w["used_percent"]) else { continue }
            let reset = num(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            windows.append(UsageWindow(label: windowLabel(seconds: num(w["limit_window_seconds"]) ?? 0), percent: u, resetsAt: reset))
        }
    }
    return ProviderUsage(id: "codex", name: "Codex", plan: (d["plan_type"] as? String)?.capitalized, windows: windows)
}

// MARK: Cursor (token from Cursor's local state DB)

private func cursorToken() throws -> String {
    let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw FetchError.msg("Cursor not installed") }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'", -1, &stmt, nil) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { throw FetchError.msg("Log in to Cursor") }
    return String(cString: c)
}

func fetchCursor() async throws -> ProviderUsage {
    let token = try cursorToken()
    var payload = token.split(separator: ".").dropFirst().first.map(String.init) ?? ""
    payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let pd = Data(base64Encoded: payload),
          let claims = try JSONSerialization.jsonObject(with: pd) as? [String: Any],
          let sub = (claims["sub"] as? String)?.split(separator: "|").last else { throw FetchError.msg("Bad Cursor token") }

    var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
    req.setValue("WorkosCursorSessionToken=\(sub)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
    let d = try await json(req)

    let reset = parseISO(d["billingCycleEnd"])
    var windows: [UsageWindow] = []
    if let plan = (d["individualUsage"] as? [String: Any])?["plan"] as? [String: Any] {
        if let a = num(plan["autoPercentUsed"]) { windows.append(UsageWindow(label: "Auto", percent: a, resetsAt: reset)) }
        if let a = num(plan["apiPercentUsed"]) { windows.append(UsageWindow(label: "API", percent: a, resetsAt: reset)) }
    }
    return ProviderUsage(id: "cursor", name: "Cursor", plan: (d["membershipType"] as? String)?.capitalized, windows: windows)
}

// MARK: Grok Bot (Anysphere app; same Cursor account, Connect RPC on api2.cursor.sh)

func fetchGrokBot() async throws -> ProviderUsage {
    var req = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(try cursorToken())", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    req.httpBody = Data("{}".utf8)
    let d = try await json(req)
    let w = UsageWindow(label: "Week", percent: num(d["usagePercent"]) ?? 0, resetsAt: parseISO(d["nextResetTimestampUtc"]))
    let plan = (d["grokPlanLabel"] as? String) ?? (d["cursorPlanName"] as? String)
    return ProviderUsage(id: "grokbot", name: "Grok Bot", plan: plan, windows: [w])
}

// MARK: All

func fetchAll() async -> UsageSnapshot {
    @Sendable func wrap(_ id: String, _ name: String, _ f: () async throws -> ProviderUsage) async -> ProviderUsage {
        do { return try await f() } catch {
            return ProviderUsage(id: id, name: name, plan: nil, windows: [], error: error.localizedDescription)
        }
    }
    async let claude = wrap("claude", "Claude", fetchClaude)
    async let codex = wrap("codex", "Codex", fetchCodex)
    async let cursor = wrap("cursor", "Cursor", fetchCursor)
    async let grokBot = wrap("grokbot", "Grok Bot", fetchGrokBot)
    return UsageSnapshot(updatedAt: Date(), providers: await [claude, codex, cursor, grokBot])
}

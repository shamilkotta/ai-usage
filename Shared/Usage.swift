import Foundation

struct UsageWindow: Codable, Hashable {
    var label: String
    var percent: Double
    var resetsAt: Date?
}

struct ProviderUsage: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var plan: String?
    var windows: [UsageWindow]
    var error: String?
}

struct UsageSnapshot: Codable {
    var updatedAt: Date
    var providers: [ProviderUsage]
}

enum UsageStore {
    // Real home, not the sandbox container home the widget would otherwise get.
    static var dir: URL {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        return URL(fileURLWithPath: home).appendingPathComponent(".ai-usage-widget", isDirectory: true)
    }
    static var file: URL { dir.appendingPathComponent("usage.json") }

    static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(UsageSnapshot.self, from: data)
    }

    static func save(_ snap: UsageSnapshot) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(snap).write(to: file, options: .atomic)
    }
}

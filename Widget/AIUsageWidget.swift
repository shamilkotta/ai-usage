import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: context.isPreview ? .sample : UsageStore.load() ?? .sample))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: .now, snapshot: UsageStore.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
    }
}

extension UsageSnapshot {
    static let sample = UsageSnapshot(updatedAt: .now, providers: [
        .init(id: "claude", name: "Claude", plan: "Max", windows: [.init(label: "5h", percent: 42, resetsAt: .now + 7200), .init(label: "Week", percent: 30, resetsAt: .now + 200_000)]),
        .init(id: "codex", name: "Codex", plan: "Plus", windows: [.init(label: "5h", percent: 10, resetsAt: .now + 9000)]),
        .init(id: "cursor", name: "Cursor", plan: "Pro", windows: [.init(label: "Auto", percent: 21, resetsAt: .now + 900_000), .init(label: "API", percent: 100, resetsAt: .now + 900_000)]),
    ])
}

private func color(_ p: Double) -> Color { p >= 90 ? .red : p >= 70 ? .orange : .green }

private func shortReset(_ d: Date?, from now: Date) -> String {
    guard let d else { return "" }
    let s = max(0, d.timeIntervalSince(now))
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86_400 { return "\(Int(s / 3600))h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60))m" }
    return "\(Int(s / 86_400))d \(Int(s.truncatingRemainder(dividingBy: 86_400) / 3600))h"
}

struct WindowView: View {
    let w: UsageWindow
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(w.label).foregroundStyle(.secondary)
                if w.resetsAt != nil {
                    Text("↻ " + shortReset(w.resetsAt, from: now))
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 2)
                Text("\(Int(w.percent.rounded()))%").fontWeight(.semibold).foregroundStyle(color(w.percent))
            }
            .font(.system(size: 10))
            .lineLimit(1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color(w.percent)).frame(width: g.size.width * min(w.percent, 100) / 100)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProviderRow: View {
    let p: ProviderUsage
    let now: Date
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(p.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if let plan = p.plan?.replacingOccurrences(of: p.name, with: "").trimmingCharacters(in: .whitespaces), !plan.isEmpty {
                    Text(plan).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 54, alignment: .leading)
            if let e = p.error {
                Text(e).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            } else {
                ForEach(p.windows, id: \.label) { WindowView(w: $0, now: now) }
            }
        }
    }
}

struct WidgetView: View {
    let entry: Entry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family
    private var bg: Color { scheme == .dark ? .black : .white }
    var body: some View {
        if let snap = entry.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snap.providers) { p in
                    ProviderRow(p: p, now: entry.date)
                    if p.id != snap.providers.last?.id { Spacer(minLength: 4) }
                }
                if family == .systemLarge {
                    Spacer(minLength: 8)
                    Text("Updated \(snap.updatedAt, style: .relative) ago")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            .containerBackground(bg, for: .widget)
        } else {
            Text("Open “AI Usage” once to start fetching.")
                .font(.caption).foregroundStyle(.secondary)
                .containerBackground(bg, for: .widget)
        }
    }
}

@main
struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIUsageWidget", provider: Provider()) {
            // Notification Center can hand the widget a light scheme even in Dark Mode, so follow the system setting.
            WidgetView(entry: $0).environment(\.colorScheme, UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light)
        }
            .configurationDisplayName("AI Usage")
            .description("Claude, Codex, Cursor and Grok Bot plan limits.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

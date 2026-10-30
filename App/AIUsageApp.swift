import AppKit
import ServiceManagement
import WidgetKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? SMAppService.mainApp.register()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // Opening the app from Finder/Spotlight while it's running forces a refresh.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refresh()
        return false
    }

    private func refresh() {
        Task {
            try? UsageStore.save(await fetchAll())
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
    }
}

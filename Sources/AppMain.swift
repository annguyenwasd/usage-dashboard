import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["UD_DEBUG_WINDOWS"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for window in NSApp.windows {
                NSLog("UD window class=%@ level=%ld visible=%d frame=%@", String(describing: type(of: window)), window.level.rawValue, window.isVisible ? 1 : 0, NSStringFromRect(window.frame))
            }
        }
    }
}

@main
struct UsageDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store)
        } label: {
            Text(store.menuBarLabel).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

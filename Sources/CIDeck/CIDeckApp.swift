import AppKit
import SwiftUI

@main
struct CIDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings: AppSettings
    @StateObject private var store: RunsStore

    init() {
        let settings = AppSettings()
        let store = RunsStore(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(settings)
                .environmentObject(store)
        } label: {
            MenuBarLabel(status: store.aggregate)
        }
        .menuBarExtraStyle(.window)

        Window("CIDeck — Cấu hình", id: SettingsWindow.id) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: LSUIElement already does this for the bundled app, but
        // `swift run` builds have no Info.plist to read it from.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

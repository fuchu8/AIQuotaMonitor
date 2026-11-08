import Foundation
import AppKit
import SwiftUI

/// NSApplication.delegate 是 weak，需要在这里强引用住
public nonisolated(unsafe) var keepAliveDelegate: AppDelegate?

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var desktopWindow: DesktopQuotaWindowController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            statusBar = StatusBarController()
            let desktop = DesktopQuotaWindowController()
            desktopWindow = desktop
            desktop.start()
            QuotaStore.shared.start()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            self.handle(urls: urls)
        }
    }

    public func application(_ application: NSApplication, openFile filename: String) -> Bool {
        false
    }

    @MainActor
    private func handle(urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "aiquotamonitor" {
            let host = (url.host ?? url.path).lowercased()
            if host.contains("desktop") {
                SettingsStore.shared.desktopWindowVisible = true
                desktopWindow?.show()
            } else {
                NotificationCenter.default.post(name: .aqmOpenPanel, object: nil)
                statusBar?.presentIfNeeded()
            }
            break
        }
    }
}

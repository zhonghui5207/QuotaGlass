import AppKit
import SwiftUI

@MainActor
@main
struct QuotaGlassMain {
    private static var delegate: AppDelegate?

    static func main() {
        if let path = ProcessInfo.processInfo.environment["QG_SNAPSHOT"] {
            renderSnapshot(to: path)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    /// Headless render of the popover to a PNG, for design verification without screen-recording permission.
    @MainActor
    static func renderSnapshot(to path: String) {
        _ = NSApplication.shared
        let store = QuotaStore()
        let sem = DispatchSemaphore(value: 0)
        Task { await store.refresh(); sem.signal() }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // Dark moss background standing in for a wallpaper behind the clear glass.
        let snapshotView = PopoverRootView(store: store)
            .background(Color(red: 0.18, green: 0.24, blue: 0.16))
        let renderer = ImageRenderer(content: snapshotView)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("snapshot failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot written: \(path)")

        // Also emit the menu-bar badge for verification.
        let defaults = defaultMenuBarKeys(store.quotas)
        let badge = MenuBarBadge.make(
            snapshots: store.quotas.filter { defaults.contains(accountKey($0)) }
        )
        if let tiff = badge.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let badgePng = rep.representation(using: .png, properties: [:]) {
            try? badgePng.write(to: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent + "/qg_menubar.png"))
            print("menubar badge written")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: GlassPanelController!
    private let store = QuotaStore()
    private var eventMonitor: Any?
    private var settingsWindow: NSWindow?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = GlassPanelController(store: store)
        setupStatusItem()
        setupDismissMonitor()
        setupAutoRefresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings), name: .qgOpenSettings, object: nil
        )
        NotificationCenter.default.addObserver(
            forName: .qgPrefsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusTitle() }
        }
        if ProcessInfo.processInfo.environment["QG_SHOWPANEL"] != nil {
            Task { await store.refresh(); panel.showDebug() }
        } else if ProcessInfo.processInfo.environment["QG_SHOWSETTINGS"] != nil {
            Task { await store.refresh(); openSettings() }
        } else {
            Task { await store.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        refreshTimer?.invalidate()
    }

    /// Keeps the menu-bar badge honest while the panel stays closed: a 1-minute
    /// tick refreshes once data is older than the user-chosen interval, and the
    /// Mac waking from sleep triggers an immediate catch-up.
    private func setupAutoRefresh() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.store.refreshIfOlder(than: TimeInterval(PrefsStore.shared.refreshInterval))
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.store.refreshIfStale() }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePanel)
        button.target = self
        button.imagePosition = .imageLeading
        updateStatusTitle()
        store.onChange = { [weak self] in
            self?.updateStatusTitle()
        }
    }

    private func setupDismissMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.panel.close()
            }
        }
    }

    @objc private func openSettings() {
        panel.close()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "QuotaGlass 设置"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsRootView(store: store))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            panel.close()
        } else {
            panel.show(relativeTo: button)
            Task { await store.refreshIfStale() }
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = MenuBarBadge.make(snapshots: menuBarSnapshots())
        button.imagePosition = .imageOnly
        button.toolTip = "QuotaGlass — AI quota monitor"
    }

    /// Accounts the user checked for the menu bar; unconfigured accounts follow
    /// the default rule (first Codex + first Claude).
    private func menuBarSnapshots() -> [QuotaSnapshot] {
        let defaults = defaultMenuBarKeys(store.quotas)
        return store.quotas.filter { snapshot in
            PrefsStore.shared.menuBarShow[accountKey(snapshot)] ?? defaults.contains(accountKey(snapshot))
        }
    }
}

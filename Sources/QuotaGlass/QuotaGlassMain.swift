import AppKit
import SwiftUI

@MainActor
@main
struct QuotaGlassMain {
    private static var delegate: AppDelegate?

    static func main() {
        if ProcessInfo.processInfo.environment["QG_SAKANA_DEBUG"] != nil {
            printSakanaDebug()
            return
        }
        if let path = ProcessInfo.processInfo.environment["QG_SNAPSHOT"] {
            renderSnapshot(to: path)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.mainMenu = makeMainMenu()
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    /// Accessory apps get no menu bar by default, which silently disables the
    /// standard edit key equivalents (⌘V/⌘C/⌘X/⌘A/⌘Z) in every text field —
    /// e.g. pasting the authorization code in the login sheets. An invisible
    /// main menu with an Edit menu restores them via the responder chain.
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu

        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return mainMenu
    }

    @MainActor
    static func printSakanaDebug() {
        _ = NSApplication.shared
        let sem = DispatchSemaphore(value: 0)
        Task {
            print(await SakanaUsage.debugReport())
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
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
        let activity = PopoverActivity()
        activity.isVisible = true
        let snapshotView = PopoverRootView(store: store, activity: activity)
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
    private var prefsObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = GlassPanelController(store: store)
        // Construct preferences at launch so an enabled notification setting
        // immediately checks/request system authorization, even before the
        // first quota refresh completes.
        _ = PrefsStore.shared
        setupStatusItem()
        setupDismissMonitor()
        setupAutoRefresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings), name: .qgOpenSettings, object: nil
        )
        prefsObserver = NotificationCenter.default.addObserver(
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
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
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

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
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
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "QuotaGlass 设置"
            window.minSize = NSSize(width: 460, height: 360)
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

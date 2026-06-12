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
        let snapshotView = PopoverRootView(store: store)
            .background(Color(red: 0.93, green: 0.95, blue: 0.98))
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
        let badge = MenuBarBadge.make(
            codex: store.primaryQuota(matching: "Codex"),
            claude: store.primaryQuota(matching: "Claude")
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = GlassPanelController(store: store)
        setupStatusItem()
        setupDismissMonitor()
        if ProcessInfo.processInfo.environment["QG_SHOWPANEL"] != nil {
            Task { await store.refresh(); panel.showDebug() }
        } else {
            Task { await store.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
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
        let codex = store.primaryQuota(matching: "Codex")
        let claude = store.primaryQuota(matching: "Claude")
        button.title = ""
        button.image = MenuBarBadge.make(codex: codex, claude: claude)
        button.imagePosition = .imageOnly
        button.toolTip = "QuotaGlass — AI quota monitor"
    }
}

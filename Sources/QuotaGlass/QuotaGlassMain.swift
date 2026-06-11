import AppKit
import SwiftUI

@MainActor
@main
struct QuotaGlassMain {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = QuotaStore()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        Task { await store.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover)
        button.target = self
        button.imagePosition = .imageLeading
        updateStatusTitle()
        store.onChange = { [weak self] in
            self?.updateStatusTitle()
        }
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 620)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(store: store)
                .frame(width: 420)
        )

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await store.refreshIfStale() }
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let codex = store.primaryQuota(matching: "Codex")?.fiveHourRemaining
        let claude = store.primaryQuota(matching: "Claude")?.fiveHourRemaining

        var parts: [String] = []
        if let codex { parts.append("◌ \(Int(codex.rounded()))%") }
        if let claude { parts.append("✦ \(Int(claude.rounded()))%") }
        if parts.isEmpty { parts = ["QuotaGlass"] }

        let title = parts.joined(separator: "  ")
        let attr = NSMutableAttributedString(string: title)
        attr.addAttributes([
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ], range: NSRange(location: 0, length: attr.length))
        button.attributedTitle = attr
        button.toolTip = "QuotaGlass — AI quota monitor"
    }
}

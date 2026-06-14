import AppKit
import SwiftUI

// A transparent, borderless floating panel hosting the SwiftUI content inside an
// AppKit NSGlassEffectView (macOS 26 Liquid Glass). The window is fully clear so
// the desktop behind it is sampled and refracted by the glass — matching the
// macOS 26 widget look. Falls back to a behind-window blur on older systems.

@MainActor
final class GlassPanelController {
    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>
    private let glassContainer: NSView

    var isVisible: Bool { panel.isVisible }

    init(store: QuotaStore) {
        let host = NSHostingView(rootView: AnyView(PopoverRootView(store: store)))
        host.sizingOptions = [.intrinsicContentSize]
        host.autoresizingMask = [.width, .height]
        self.hosting = host

        // Ghostty-style alignment (background-opacity 0, blur off): zero blur,
        // zero material — the content floats directly over the desktop. The
        // rounded outline is drawn by the SwiftUI root view.
        let container = NSView()
        host.frame = container.bounds
        container.addSubview(host)
        self.glassContainer = container

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No slab shadow — a fully transparent panel with a shadow reads as a
        // ghostly rectangle over the wallpaper.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        glassContainer.autoresizingMask = [.width, .height]
        panel.contentView = glassContainer
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel.isVisible { close() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let width: CGFloat = 360
        let height = max(120, fitting.height)
        panel.setContentSize(NSSize(width: width, height: height))
        glassContainer.frame = NSRect(x: 0, y: 0, width: width, height: height)

        if let window = button.window {
            let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let x = buttonRect.midX - width / 2
            let y = buttonRect.minY - height - 6
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Debug: show the panel centered (for screenshot verification).
    func showDebug() {
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let width: CGFloat = 360
        let height = max(120, fitting.height)
        panel.setContentSize(NSSize(width: width, height: height))
        glassContainer.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if let screen = NSScreen.main {
            let x = screen.frame.midX - width / 2
            let y = screen.frame.midY - height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        let diag = "frame=\(panel.frame) visible=\(panel.isVisible) fitting=\(fitting) screen=\(NSScreen.main?.frame ?? .zero) glassClass=\(type(of: glassContainer)) contentView=\(String(describing: panel.contentView))"
        try? diag.write(toFile: "/tmp/qg_debug.txt", atomically: true, encoding: .utf8)
    }
}

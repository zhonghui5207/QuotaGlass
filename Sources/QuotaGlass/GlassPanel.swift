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

        let cornerRadius: CGFloat = 26
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            // Clear variant: wallpaper colors refract through. Legibility dimming
            // goes through tintColor so it rides the glass (specular highlights,
            // refraction) instead of sitting on top as a flat film.
            glass.style = .clear
            glass.contentView = host
            self.glassContainer = glass
        } else {
            // Dark blur so the white-on-glass text hierarchy stays legible.
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            host.frame = effect.bounds
            effect.addSubview(host)
            self.glassContainer = effect
        }

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
        let width: CGFloat = 340
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
        let width: CGFloat = 340
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

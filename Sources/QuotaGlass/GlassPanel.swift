import AppKit
import Combine
import SwiftUI

// A transparent, borderless floating panel hosting the SwiftUI content inside an
// AppKit NSGlassEffectView (macOS 26 Liquid Glass). The window is fully clear so
// the desktop behind it is sampled and refracted by the glass — matching the
// macOS 26 widget look. Falls back to a behind-window blur on older systems.

@MainActor
final class GlassPanelController {
    private static let contentWidth: CGFloat = 340
    private static let minimumHeight: CGFloat = 120
    private static let maximumHeight: CGFloat = 720
    private static let screenMargin: CGFloat = 8
    private static let statusBarGap: CGFloat = 6

    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>
    private let scrollView: NSScrollView
    private let glassContainer: NSView
    private let activity: PopoverActivity
    private weak var anchorButton: NSStatusBarButton?
    private var storeObserver: AnyCancellable?

    var isVisible: Bool { panel.isVisible }

    init(store: QuotaStore) {
        let activity = PopoverActivity()
        self.activity = activity
        let host = NSHostingView(rootView: AnyView(PopoverRootView(store: store, activity: activity)))
        host.sizingOptions = [.intrinsicContentSize]
        self.hosting = host

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = host
        scroll.autoresizingMask = [.width, .height]
        self.scrollView = scroll

        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 28
            glass.tintColor = nil
            glass.contentView = scroll
            container = glass
        } else {
            let visual = NSVisualEffectView()
            visual.material = .popover
            visual.blendingMode = .behindWindow
            visual.state = .active
            scroll.frame = visual.bounds
            visual.addSubview(scroll)
            container = visual
        }
        self.glassContainer = container

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 480),
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

        // Quotas, loading/error state, and the refresh timestamp are all
        // published independently. Re-measure one run-loop turn after each
        // change so SwiftUI has committed its new intrinsic size first.
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateLayout(resetScrollPosition: false)
            }
        }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel.isVisible { close() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        anchorButton = button
        activity.isVisible = true
        updateLayout(resetScrollPosition: true)
        panel.orderFrontRegardless()
    }

    func close() {
        activity.isVisible = false
        panel.orderOut(nil)
    }

    /// Debug: show the panel centered (for screenshot verification).
    func showDebug() {
        anchorButton = nil
        activity.isVisible = true
        let screen = NSScreen.main
        updateLayout(screenOverride: screen, resetScrollPosition: true)
        if let visibleFrame = screen?.visibleFrame {
            let x = visibleFrame.midX - panel.frame.width / 2
            let y = visibleFrame.midY - panel.frame.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        let diag = "frame=\(panel.frame) visible=\(panel.isVisible) fitting=\(hosting.fittingSize) screen=\(NSScreen.main?.frame ?? .zero) glassClass=\(type(of: glassContainer)) contentView=\(String(describing: panel.contentView))"
        try? diag.write(toFile: "/tmp/qg_debug.txt", atomically: true, encoding: .utf8)
    }

    private func updateLayout(screenOverride: NSScreen? = nil, resetScrollPosition: Bool) {
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let naturalHeight = max(Self.minimumHeight, fitting.height)

        let buttonRect = anchorButton.flatMap(statusButtonRect)
        let screen = screenOverride ?? screen(for: buttonRect)
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.maximumHeight)

        let availableHeight: CGFloat
        if let buttonRect {
            availableHeight = buttonRect.minY - visibleFrame.minY - Self.statusBarGap - Self.screenMargin
        } else {
            availableHeight = visibleFrame.height - 2 * Self.screenMargin
        }
        let heightLimit = max(
            min(Self.minimumHeight, visibleFrame.height),
            min(Self.maximumHeight, availableHeight)
        )
        let panelHeight = min(naturalHeight, heightLimit)
        let panelSize = NSSize(width: Self.contentWidth, height: panelHeight)

        panel.setContentSize(panelSize)
        glassContainer.frame = NSRect(origin: .zero, size: panelSize)
        scrollView.frame = glassContainer.bounds
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.contentWidth,
            height: max(1, fitting.height)
        )

        if resetScrollPosition {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        let desiredOrigin: NSPoint
        if let buttonRect {
            desiredOrigin = NSPoint(
                x: buttonRect.midX - panelSize.width / 2,
                y: buttonRect.minY - panelSize.height - Self.statusBarGap
            )
        } else {
            desiredOrigin = panel.frame.origin
        }
        panel.setFrameOrigin(clamped(origin: desiredOrigin, size: panelSize, in: visibleFrame))
    }

    private func statusButtonRect(_ button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func screen(for buttonRect: NSRect?) -> NSScreen? {
        if let buttonScreen = anchorButton?.window?.screen { return buttonScreen }
        if let buttonRect,
           let containing = NSScreen.screens.first(where: { $0.frame.intersects(buttonRect) }) {
            return containing
        }
        return panel.screen ?? NSScreen.main
    }

    private func clamped(origin: NSPoint, size: NSSize, in visibleFrame: NSRect) -> NSPoint {
        let minX = visibleFrame.minX + Self.screenMargin
        let maxX = max(minX, visibleFrame.maxX - size.width - Self.screenMargin)
        let minY = visibleFrame.minY + Self.screenMargin
        let maxY = max(minY, visibleFrame.maxY - size.height - Self.screenMargin)
        return NSPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }
}

import AppKit
import SwiftUI

// Menu-bar status item content: each shown service draws its logo (template SVG)
// followed by its remaining-percent text. Rendered through SwiftUI ImageRenderer
// (which rasterizes the bundled SVGs reliably) into a template NSImage so the
// menu bar tints it for light/dark automatically.

@MainActor
enum MenuBarBadge {
    static func make(codex: QuotaSnapshot?, claude: QuotaSnapshot?) -> NSImage {
        let renderer = ImageRenderer(content: BadgeView(codex: codex, claude: claude))
        renderer.scale = 2
        renderer.isOpaque = false
        if let image = renderer.nsImage {
            image.isTemplate = true
            return image
        }
        // Fallback: minimal blank image so the status item never disappears.
        let fallback = NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }
}

private struct BadgeView: View {
    let codex: QuotaSnapshot?
    let claude: QuotaSnapshot?

    var body: some View {
        HStack(spacing: 9) {
            if let codex { segment(logo: "codex", snapshot: codex) }
            if let claude { segment(logo: "claude", snapshot: claude) }
        }
        .frame(height: 16)
        .foregroundStyle(.black)
    }

    private func segment(logo: String, snapshot: QuotaSnapshot) -> some View {
        HStack(spacing: 3) {
            logoImage(logo)
            Text("\(Int(snapshot.fiveHourRemaining.rounded()))%")
                .font(.system(size: 12, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(.black)
        }
    }

    @ViewBuilder
    private func logoImage(_ name: String) -> some View {
        if let nsImage = LogoCache.image(named: name) {
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.black)
                .frame(width: 15, height: 15)
        }
    }
}

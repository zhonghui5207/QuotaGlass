import AppKit
import SwiftUI

// Menu-bar status item content: each shown account draws its service logo
// (template SVG) followed by its remaining-percent text. Rendered through
// SwiftUI ImageRenderer (which rasterizes the bundled SVGs reliably) into a
// template NSImage so the menu bar tints it for light/dark automatically.

@MainActor
enum MenuBarBadge {
    static func make(snapshots: [QuotaSnapshot]) -> NSImage {
        guard !snapshots.isEmpty else {
            // Nothing selected: a plain gauge glyph keeps the item clickable.
            if let symbol = NSImage(systemSymbolName: "gauge", accessibilityDescription: "QuotaGlass") {
                symbol.isTemplate = true
                return symbol
            }
            let blank = NSImage(size: NSSize(width: 18, height: 18))
            blank.isTemplate = true
            return blank
        }
        let renderer = ImageRenderer(content: BadgeView(snapshots: snapshots, initials: initials(for: snapshots)))
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

    /// Alias initials are always shown when the user set an alias. Without an
    /// alias, only duplicated services get an account-name initial.
    private static func initials(for snapshots: [QuotaSnapshot]) -> [UUID: String] {
        var serviceCounts: [String: Int] = [:]
        for snapshot in snapshots { serviceCounts[snapshot.serviceName, default: 0] += 1 }
        var result: [UUID: String] = [:]
        for snapshot in snapshots {
            let key = accountKey(snapshot)
            if let alias = AliasStore.shared.alias(for: key), let first = alias.first {
                result[snapshot.id] = String(first).uppercased()
            } else if (serviceCounts[snapshot.serviceName] ?? 0) > 1, let first = snapshot.accountName.first {
                result[snapshot.id] = String(first).uppercased()
            }
        }
        return result
    }
}

private struct BadgeView: View {
    let snapshots: [QuotaSnapshot]
    let initials: [UUID: String]

    var body: some View {
        HStack(spacing: 9) {
            ForEach(snapshots) { snapshot in
                segment(snapshot)
            }
        }
        .frame(height: 16)
        .foregroundStyle(.black)
    }

    private func segment(_ snapshot: QuotaSnapshot) -> some View {
        HStack(spacing: 3) {
            serviceMark(snapshot)
            if let initial = initials[snapshot.id] {
                Text(initial)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.black)
            }
            Text(badgeText(for: snapshot))
                .font(.system(size: 12, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(.black)
        }
    }

    private func badgeText(for snapshot: QuotaSnapshot) -> String {
        if snapshot.isAPIUsage {
            if hasWindowData(snapshot) {
                return "\(Int(snapshot.fiveHourRemaining.rounded()))%"
            }
            let text = snapshot.apiPrimaryText ?? "API"
            return text == "API key OK" ? "API" : text
        }
        return "\(Int(snapshot.fiveHourRemaining.rounded()))%"
    }

    private func hasWindowData(_ snapshot: QuotaSnapshot) -> Bool {
        snapshot.fiveHourReset != "无" || snapshot.weeklyReset != "无" || snapshot.fiveHourUsed > 0 || snapshot.weeklyUsed > 0
    }

    @ViewBuilder
    private func serviceMark(_ snapshot: QuotaSnapshot) -> some View {
        if snapshot.isCodex {
            logoImage("codex")
        } else if snapshot.isClaude {
            logoImage("claude")
        } else if snapshot.isSakana {
            logoImage("sakana")
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

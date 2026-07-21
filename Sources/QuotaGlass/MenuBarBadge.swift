import AppKit
import SwiftUI

// Menu-bar status item content: each shown account draws its service logo
// (template SVG) followed by its remaining-percent text. Rendered through
// SwiftUI ImageRenderer (which rasterizes the bundled SVGs reliably) into a
// template NSImage so the menu bar tints it for light/dark automatically.

@MainActor
enum MenuBarBadge {
    /// Rasterizing through ImageRenderer is comparatively expensive, and one
    /// refresh publishes several quota updates in a row. Keep the last image
    /// and only re-render when badge-visible content actually changes.
    private static var cached: (key: Int, image: NSImage)?

    static func make(snapshots: [QuotaSnapshot]) -> NSImage {
        let key = contentKey(for: snapshots)
        if let cached, cached.key == key { return cached.image }
        let image = render(snapshots: snapshots)
        cached = (key, image)
        return image
    }

    /// Hashes every field that can influence the rendered badge, including
    /// aliases (which drive the initials and accessibility text).
    private static func contentKey(for snapshots: [QuotaSnapshot]) -> Int {
        var hasher = Hasher()
        for snapshot in snapshots {
            hasher.combine(snapshot.id)
            hasher.combine(snapshot.serviceName)
            hasher.combine(snapshot.accountName)
            hasher.combine(snapshot.planName)
            hasher.combine(snapshot.isAPIUsage)
            hasher.combine(snapshot.fiveHourRemaining)
            hasher.combine(snapshot.weeklyRemaining)
            hasher.combine(snapshot.apiPrimaryText)
            hasher.combine(AliasStore.shared.alias(for: accountKey(snapshot)))
        }
        return hasher.finalize()
    }

    private static func render(snapshots: [QuotaSnapshot]) -> NSImage {
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
            image.accessibilityDescription = accessibilityDescription(for: snapshots)
            return image
        }
        // Keep the status item discoverable if ImageRenderer ever fails.
        let fallback = NSImage(systemSymbolName: "gauge", accessibilityDescription: "QuotaGlass")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    /// Alias initials are always shown when the user set an alias. Without an
    /// alias, only duplicated services get an account-name initial.
    private static func initials(for snapshots: [QuotaSnapshot]) -> [String: String] {
        var serviceCounts: [String: Int] = [:]
        for snapshot in snapshots { serviceCounts[snapshot.serviceName, default: 0] += 1 }
        var result: [String: String] = [:]
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

    private static func accessibilityDescription(for snapshots: [QuotaSnapshot]) -> String {
        let values = snapshots.map { snapshot in
            let account = AliasStore.shared.alias(for: accountKey(snapshot)) ?? snapshot.displaySubtitle
            let usage: String
            if let remaining = snapshot.fiveHourRemaining {
                usage = "五小时剩余 \(Int(remaining.rounded()))%"
            } else if let primary = snapshot.apiPrimaryText, !primary.isEmpty {
                usage = primary
            } else {
                usage = "用量未知"
            }
            return "\(displayTitle(snapshot)) \(account)，\(usage)"
        }
        return "QuotaGlass。" + values.joined(separator: "；")
    }
}

private struct BadgeView: View {
    let snapshots: [QuotaSnapshot]
    let initials: [String: String]

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
            if let remaining = snapshot.fiveHourRemaining {
                return "\(Int(remaining.rounded()))%"
            }
            if let remaining = snapshot.weeklyRemaining {
                return "WK \(Int(remaining.rounded()))%"
            }
            let text = snapshot.apiPrimaryText ?? "API"
            return text == "API key OK" ? "API" : text
        }
        guard let remaining = snapshot.fiveHourRemaining else { return "—" }
        return "\(Int(remaining.rounded()))%"
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

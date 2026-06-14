import SwiftUI
import AppKit

// Layout and visuals replicate the cc-bar popover 1:1 (github.com/nanvon/cc-bar),
// adapted to QuotaGlass's local usage-checker data source.

// MARK: - Theme
// Clear Liquid Glass look: monochrome white vibrancy over a dimming layer,
// color reserved exclusively for low-quota warnings.

enum Theme {
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.65)
    static let textTertiary = Color.white.opacity(0.42)
    static let divider = Color.white.opacity(0.14)
    static let barTrack = Color.white.opacity(0.12)

    /// White normally; orange under 30% remaining, red under 10%.
    static func tint(remaining: Double) -> Color {
        if remaining < 10 { return Color(red: 1.00, green: 0.33, blue: 0.27) }
        if remaining < 30 { return Color(red: 1.00, green: 0.64, blue: 0.26) }
        return .white
    }

    /// JetBrainsMono Nerd Font (Ghostty alignment; base style Medium), with a
    /// system-font fallback when the font isn't installed.
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "JetBrainsMonoNF-Bold"
        case .semibold: name = "JetBrainsMonoNF-SemiBold"
        default: name = "JetBrainsMonoNF-Medium"
        }
        guard NSFont(name: name, size: size) != nil else {
            return .system(size: size, weight: weight)
        }
        return .custom(name, size: size)
    }
}

func displayTitle(_ snapshot: QuotaSnapshot) -> String {
    snapshot.isClaude ? "Claude Code" : snapshot.serviceName
}

private func logoName(_ snapshot: QuotaSnapshot) -> String {
    if snapshot.isClaude { return "claude" }
    if snapshot.isCodex { return "codex" }
    return ""
}

// MARK: - Root

struct PopoverRootView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject private var aliases = AliasStore.shared
    @State private var refreshRotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        // Soft per-glyph shadow keeps white text readable over light wallpaper
        // without any blur/material behind it.
        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
        // Ghostty 等价 background-opacity ≈ 0.40：纯透明度垫底，无模糊。
        .background(Color.black.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text("用量")
                    .font(Theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.font(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "drop.fill")
                .font(.system(size: 9))
                .foregroundStyle(statusColor)
                .padding(.trailing, 4)

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(Theme.font(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(refreshRotation))
                    .animation(.easeInOut(duration: 0.7), value: refreshRotation)
            }
            .buttonStyle(PopoverIconButtonStyle())

            Button {
                NotificationCenter.default.post(name: .qgOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(Theme.font(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(PopoverIconButtonStyle())

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(Theme.font(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(PopoverIconButtonStyle())
        }
        .padding(.top, 14)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        guard let last = store.lastRefresh else { return "等待数据" }
        let seconds = max(0, Int(Date().timeIntervalSince(last)))
        let age: String
        if seconds < 60 { age = "\(seconds)s" }
        else if seconds < 3600 { age = "\(seconds / 60)m" }
        else if seconds < 86400 { age = "\(seconds / 3600)h" }
        else { age = "\(seconds / 86400)d" }
        return "\(age) 前已刷新"
    }

    private var statusColor: Color {
        switch store.state {
        case .loaded: Color.white.opacity(0.9)
        case .loading: Color.white.opacity(0.9)
        case .failed: .orange
        case .idle: Theme.textTertiary
        }
    }

    private func refresh() {
        refreshRotation += 360
        Task { await store.refresh() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.quotas.isEmpty && store.state == .loading {
            VStack(spacing: 8) {
                ProgressView()
                Text("正在读取用量…")
                    .font(Theme.font(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(orderedQuotas.enumerated()), id: \.element.id) { index, snapshot in
                    if index > 0 {
                        Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
                    }
                    ServiceBlockView(snapshot: snapshot)
                }
                if case .failed(let message) = store.state {
                    Text(shortError(message))
                        .font(Theme.font(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private func shortError(_ error: String) -> String {
        let line = error.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count <= 110 ? line : String(line.prefix(107)) + "..."
    }

    /// Every account as its own row, Codex first then Claude then anything else,
    /// preserving original order within each service.
    private var orderedQuotas: [QuotaSnapshot] {
        func rank(_ s: QuotaSnapshot) -> Int {
            if s.isCodex { return 0 }
            if s.isClaude { return 1 }
            return 2
        }
        return store.quotas.enumerated().sorted { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - ServiceBlockView

private struct ServiceBlockView: View {
    let snapshot: QuotaSnapshot

    private var fiveHourTint: Color { Theme.tint(remaining: snapshot.fiveHourRemaining) }
    private var weeklyTint: Color { Theme.tint(remaining: snapshot.weeklyRemaining) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            bodyRow
            weeklyRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerRow: some View {
        HStack(spacing: 9) {
            ServiceTile(logoName: logoName(snapshot), fallback: String(snapshot.serviceName.prefix(1)))

            (
                Text(displayTitle(snapshot))
                    .font(Theme.font(size: 13, weight: .semibold))
                    .kerning(-0.1)
                    .foregroundColor(Theme.textPrimary)
                + Text("   ")
                + Text(AliasStore.shared.alias(for: accountKey(snapshot)) ?? snapshot.displaySubtitle)
                    .font(Theme.font(size: 11))
                    .foregroundColor(Color.white.opacity(0.55))
            )
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 0)

            if snapshot.isStale {
                Text("旧数据")
                    .font(Theme.font(size: 9))
                    .foregroundStyle(.orange)
            }
            // QuotaGlass signature: a droplet, tinted by quota tier
            // (white = healthy, orange = <30%, red = <10%), orange when stale.
            Image(systemName: "drop.fill")
                .font(.system(size: 8))
                .foregroundStyle(
                    snapshot.isStale
                        ? Color.orange
                        : Theme.tint(remaining: snapshot.fiveHourRemaining).opacity(0.9)
                )
        }
    }

    private var bodyRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .center, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(snapshot.fiveHourRemaining.rounded()))")
                        .font(Theme.font(size: 32, weight: .semibold))
                        .monospacedDigit()
                        .kerning(-0.8)
                        .foregroundStyle(fiveHourTint)
                        .lineLimit(1)
                    Text("%")
                        .font(Theme.font(size: 16, weight: .semibold))
                        .foregroundStyle(fiveHourTint.opacity(0.75))
                }
                .fixedSize()

                Text("5-HOUR · 五小时")
                    .font(Theme.font(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressBar(value: snapshot.fiveHourRemaining / 100, tint: fiveHourTint, height: 6)

                HStack(spacing: 5) {
                    Text("重置")
                        .font(Theme.font(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(snapshot.fiveHourReset)
                        .font(Theme.font(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var weeklyRow: some View {
        HStack(spacing: 10) {
            Text("WK")
                .font(Theme.font(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 36, alignment: .leading)

            ProgressBar(value: snapshot.weeklyRemaining / 100, tint: weeklyTint, height: 2.5)

            Text("\(Int(snapshot.weeklyRemaining.rounded()))%")
                .font(Theme.font(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(weeklyTint)

            Text(snapshot.weeklyReset)
                .font(Theme.font(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }

}

// MARK: - ProgressBar (cc-bar)

struct ProgressBar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.barTrack)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
                Capsule()
                    .fill(
                        // Lit-from-above glass tube: bright top edge, translucent body.
                        LinearGradient(
                            colors: [tint.opacity(0.95), tint.opacity(0.55)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: max(height, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
    }

    private var clamped: CGFloat { max(0, min(1, CGFloat(value))) }
}

// MARK: - ServiceTile (cc-bar)

struct ServiceTile: View {
    let logoName: String
    let fallback: String
    var size: CGFloat = 22
    var logoSize: CGFloat = 14
    var cornerRadius: CGFloat = 6

    /// Brand tiles: OpenAI black-on-white, Claude white-on-terracotta (#D97757).
    private static let claudeBrand = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    private var isOpenAIBrand: Bool { logoName == "codex" }
    private var isClaudeBrand: Bool { logoName == "claude" }
    private var background: Color {
        if isOpenAIBrand { return .white }
        if isClaudeBrand { return Self.claudeBrand }
        return Color.white.opacity(0.14)
    }
    private var foreground: Color { isOpenAIBrand ? .black : .white }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                if isOpenAIBrand {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                }
            }
            .overlay(logoView)
    }

    @ViewBuilder
    private var logoView: some View {
        if let nsImage = LogoCache.image(named: logoName) {
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(foreground)
                .frame(width: logoSize, height: logoSize)
        } else {
            Text(fallback)
                .font(Theme.font(size: logoSize * 0.7, weight: .semibold))
                .foregroundStyle(foreground)
        }
    }
}

enum LogoCache {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func image(named name: String) -> NSImage? {
        if name.isEmpty { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

// MARK: - Liquid Glass container

/// Wraps content in Apple's transparent Liquid Glass (macOS 26+), falling back
/// to a translucent material on older systems.
struct GlassContainer<Content: View>: View {
    var cornerRadius: CGFloat = 26
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}

// MARK: - Icon button style (cc-bar)

struct PopoverIconButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 26, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering && isEnabled ? Color.white.opacity(0.12) : .clear)
            )
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

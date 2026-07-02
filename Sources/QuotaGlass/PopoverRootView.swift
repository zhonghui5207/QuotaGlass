import SwiftUI
import AppKit

// Liquid Glass popover tuned for a native macOS menu-bar utility.

// MARK: - Theme
// Monochrome vibrancy with color reserved for low-quota warnings.

enum Theme {
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.36)
    static let divider = Color.white.opacity(0.10)
    static let barTrack = Color.white.opacity(0.12)

    /// White normally; orange under 30% remaining, red under 10%.
    static func tint(remaining: Double) -> Color {
        if remaining < 10 { return Color(red: 1.00, green: 0.33, blue: 0.27) }
        if remaining < 30 { return Color(red: 1.00, green: 0.64, blue: 0.26) }
        return .white
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

func displayTitle(_ snapshot: QuotaSnapshot) -> String {
    if snapshot.isSakana { return "Sakana API" }
    return snapshot.isClaude ? "Claude Code" : snapshot.serviceName
}

private func logoName(_ snapshot: QuotaSnapshot) -> String {
    if snapshot.isClaude { return "claude" }
    if snapshot.isCodex { return "codex" }
    if snapshot.isSakana { return "sakana" }
    return ""
}

// MARK: - Root

struct PopoverRootView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject private var aliases = AliasStore.shared
    @State private var refreshRotation: Double = 0

    var body: some View {
        // On macOS 26 the hosting NSGlassEffectView supplies the entire widget
        // chrome (refraction, rim light, shadow); any extra fill or border here
        // just muddies the clear glass, so the stack stays bare.
        if #available(macOS 26.0, *) {
            contentStack
        } else {
            contentStack
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.black.opacity(0.30))
                )
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.10),
                                    Color.white.opacity(0.03)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.22), radius: 18, y: 9)
                .shadow(color: .black.opacity(0.20), radius: 1, y: 1)
        }
    }

    private var contentStack: some View {
        VStack(spacing: 0) {
            header
            GlassHairline()
            content
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 3) {
            VStack(alignment: .leading, spacing: 1) {
                Text("用量")
                    .font(Theme.font(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.font(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer()

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
        .padding(.top, 15)
        .padding(.horizontal, 13)
        .padding(.bottom, 10)
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

    private func refresh() {
        refreshRotation += 360
        Task { await store.refresh() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.quotas.isEmpty && store.state == .loading {
            VStack(spacing: 7) {
                ProgressView()
                Text("正在读取用量…")
                    .font(Theme.font(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            if #available(macOS 26.0, *) {
                GlassEffectContainer { blockList }
            } else {
                blockList
            }
        }
    }

    private var blockList: some View {
        VStack(spacing: 0) {
            ForEach(Array(orderedQuotas.enumerated()), id: \.element.id) { index, snapshot in
                if index > 0 {
                    // Same 7pt the hairline row occupied; the capsule edges
                    // now do the separating.
                    Color.clear.frame(height: 1)
                        .padding(.vertical, 3)
                }
                ServiceBlockView(snapshot: snapshot)
                    .modifier(ServiceBlockGlass())
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
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
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
            if s.isSakana { return 2 }
            return 3
        }
        return store.quotas.enumerated().sorted { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - Service block glass capsule

/// Control-Center-style Liquid Glass capsule behind each service block: its
/// own lensing rim and highlights, floating on the panel's backdrop. Layout
/// is untouched — the capsule wraps the block's existing padded bounds.
private struct ServiceBlockGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        } else {
            content.background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
            )
        }
    }
}

// MARK: - ServiceBlockView

private struct ServiceBlockView: View {
    let snapshot: QuotaSnapshot

    private var fiveHourTint: Color { Theme.tint(remaining: snapshot.fiveHourRemaining) }
    private var weeklyTint: Color { Theme.tint(remaining: snapshot.weeklyRemaining) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if shouldUseQuotaLayout {
                bodyRow
                weeklyRow
            } else {
                apiBodyRow
                if hasWindowData {
                    apiQuotaRow(label: "5H", remaining: snapshot.fiveHourRemaining, reset: snapshot.fiveHourReset, tint: fiveHourTint)
                    apiQuotaRow(label: "WK", remaining: snapshot.weeklyRemaining, reset: snapshot.weeklyReset, tint: weeklyTint)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerRow: some View {
        HStack(spacing: 9) {
            ServiceTile(logoName: logoName(snapshot), fallback: String(snapshot.serviceName.prefix(1)))

            (
                Text(displayTitle(snapshot))
                    .font(Theme.font(size: 13, weight: .semibold))
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
            if let warningText = snapshot.warningText {
                Text(warningText)
                    .font(Theme.font(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var bodyRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .center, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(snapshot.fiveHourRemaining.rounded()))")
                        .font(Theme.font(size: 31, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(fiveHourTint)
                        .lineLimit(1)
                    Text("%")
                        .font(Theme.font(size: 16, weight: .semibold))
                        .foregroundStyle(fiveHourTint.opacity(0.75))
                }
                .fixedSize()

                Text("5-HOUR · 五小时")
                    .font(Theme.font(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            .frame(width: 82, alignment: .center)

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

    private var apiBodyRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .center, spacing: 4) {
                Text(snapshot.apiPrimaryText ?? "API")
                    .font(Theme.font(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 94)

                Text("API · 用量")
                    .font(Theme.font(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 94, alignment: .center)

            VStack(alignment: .leading, spacing: 6) {
                if let secondary = snapshot.apiSecondaryText, !secondary.isEmpty {
                    Text(secondary)
                        .font(Theme.font(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                if let detail = snapshot.apiDetailText, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.font(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hasWindowData: Bool {
        snapshot.fiveHourReset != "无" || snapshot.weeklyReset != "无" || snapshot.fiveHourUsed > 0 || snapshot.weeklyUsed > 0
    }

    private var shouldUseQuotaLayout: Bool {
        !snapshot.isAPIUsage || hasWindowData
    }

    private func apiQuotaRow(label: String, remaining: Double, reset: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.font(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 36, alignment: .leading)

            ProgressBar(value: remaining / 100, tint: tint, height: 2.5)

            Text("\(Int(remaining.rounded()))%")
                .font(Theme.font(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)

            Text(reset)
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
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                    )
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                tint.opacity(0.76),
                                tint.opacity(0.48)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: max(height, proxy.size.width * clamped))
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: max(1, height * 0.26))
                            .padding(.horizontal, 1)
                    }
            }
        }
        .frame(height: height)
    }

    private var clamped: CGFloat { max(0, min(1, CGFloat(value))) }
}

// MARK: - ServiceTile

struct ServiceTile: View {
    let logoName: String
    let fallback: String
    var size: CGFloat = 24
    var logoSize: CGFloat = 14
    var cornerRadius: CGFloat = 7

    /// Brand tiles: OpenAI black-on-white, Claude white-on-terracotta (#D97757), Sakana red-on-white.
    private static let claudeBrand = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    private static let sakanaBrand = Color(red: 0xEA / 255, green: 0x20 / 255, blue: 0x12 / 255)

    private var isOpenAIBrand: Bool { logoName == "codex" }
    private var isClaudeBrand: Bool { logoName == "claude" }
    private var isSakanaBrand: Bool { logoName == "sakana" }
    private var background: Color {
        if isOpenAIBrand || isSakanaBrand { return .white }
        if isClaudeBrand { return Self.claudeBrand }
        return Color.white.opacity(0.14)
    }
    private var foreground: Color {
        if isOpenAIBrand { return .black }
        if isSakanaBrand { return Self.sakanaBrand }
        return .white
    }
    private var effectiveLogoSize: CGFloat { isSakanaBrand ? logoSize + 3 : logoSize }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        (isOpenAIBrand || isSakanaBrand) ? Color.black.opacity(0.13) : Color.white.opacity(0.18),
                        lineWidth: 0.5
                    )
            }
            .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
            .overlay(logoView)
    }

    @ViewBuilder
    private var logoView: some View {
        if let nsImage = LogoCache.image(named: logoName) {
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(foreground)
                .frame(width: effectiveLogoSize, height: effectiveLogoSize)
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

private struct GlassHairline: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.white.opacity(0),
                Theme.divider,
                Color.white.opacity(0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.horizontal, 14)
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
            content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}

// MARK: - Icon button style

struct PopoverIconButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 27, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && isEnabled ? Color.white.opacity(0.10) : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(hovering && isEnabled ? 0.14 : 0),
                                lineWidth: 0.5
                            )
                    }
            )
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

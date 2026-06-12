import SwiftUI
import AppKit

// Layout and visuals replicate the cc-bar popover 1:1 (github.com/nanvon/cc-bar),
// adapted to QuotaGlass's local usage-checker data source.

// MARK: - Accent colors (cc-bar CodexAccent / ClaudeAccent)

extension Color {
    static let codexAccent = Color(red: 0x6C / 255, green: 0x6C / 255, blue: 0x70 / 255) // #6C6C70
    static let claudeAccent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) // #D97757
}

private func accent(for snapshot: QuotaSnapshot) -> Color {
    if snapshot.isClaude { return .claudeAccent }
    if snapshot.isCodex { return .codexAccent }
    return Color(red: 0.30, green: 0.50, blue: 0.86)
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
            Divider()
            content
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text("用量")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.trailing, 4)

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(refreshRotation))
                    .animation(.easeInOut(duration: 0.7), value: refreshRotation)
            }
            .buttonStyle(PopoverIconButtonStyle())

            Button {} label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PopoverIconButtonStyle())

            Button {
                NotificationCenter.default.post(name: .qgOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PopoverIconButtonStyle())

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
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
        case .loaded: .green
        case .loading: .green
        case .failed: .orange
        case .idle: .secondary
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(orderedQuotas.enumerated()), id: \.element.id) { index, snapshot in
                    if index > 0 { Divider().padding(.horizontal, 16) }
                    ServiceBlockView(snapshot: snapshot)
                }
                if case .failed(let message) = store.state {
                    Text(shortError(message))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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

    private var tint: Color { accent(for: snapshot) }

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
            ServiceTile(logoName: logoName(snapshot), fallback: String(snapshot.serviceName.prefix(1)), tint: tint)

            (
                Text(displayTitle(snapshot))
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.1)
                    .foregroundColor(.primary)
                + Text("   ")
                + Text(AliasStore.shared.alias(for: accountKey(snapshot)) ?? snapshot.displaySubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.75))
            )
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 0)

            Circle().fill(Color.green).frame(width: 6, height: 6)
        }
    }

    private var bodyRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .center, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(snapshot.fiveHourRemaining.rounded()))")
                        .font(.system(size: 32, weight: .semibold))
                        .monospacedDigit()
                        .kerning(-0.8)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    Text("%")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.75))
                }
                .fixedSize()

                Text("5-HOUR · 五小时")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.quaternary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressBar(value: snapshot.fiveHourRemaining / 100, tint: tint, height: 7)

                VStack(spacing: 1) {
                    HStack(spacing: 0) {
                        Text(snapshot.fiveHourReset)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        HStack(spacing: 10) {
                            statInline(label: "今日", value: snapshot.spendDisplay ?? "—")
                            statInline(label: "本周", value: "—")
                        }
                    }

                    HStack(spacing: 0) {
                        Text("重置")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.quaternary)
                        Spacer(minLength: 0)
                        Text("花费")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.quaternary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var weeklyRow: some View {
        HStack(spacing: 10) {
            Text("WK")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.quaternary)
                .frame(width: 36, alignment: .leading)

            ProgressBar(value: snapshot.weeklyRemaining / 100, tint: tint, height: 2.5)

            Text("\(Int(snapshot.weeklyRemaining.rounded()))%")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)

            Text(snapshot.weeklyReset)
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
        }
    }

    private func statInline(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
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
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, proxy.size.width * clamped))
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
    let tint: Color
    var size: CGFloat = 22
    var logoSize: CGFloat = 14
    var cornerRadius: CGFloat = 6

    private var isOpenAIBrand: Bool { logoName == "codex" }
    private var background: Color { isOpenAIBrand ? .white : tint }
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
                .font(.system(size: logoSize * 0.7, weight: .semibold))
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
                    .fill(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear)
            )
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

import SwiftUI
import AppKit

struct PopoverRootView: View {
    @ObservedObject var store: QuotaStore
    @State private var animateGlow = false

    var body: some View {
        ZStack {
            GlassBackdrop(animate: animateGlow)
            VStack(spacing: 16) {
                header
                quotaCards
                footer
            }
            .padding(18)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { animateGlow = true }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("QuotaGlass")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            StatusPill(state: store.state)
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(GlassIconButtonStyle())
            .disabled(store.state == .loading)
        }
    }

    private var subtitle: String {
        if let last = store.lastRefresh {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "refreshed \(formatter.localizedString(for: last, relativeTo: Date()))"
        }
        return "AI quota monitor · glass preview"
    }

    private var quotaCards: some View {
        VStack(spacing: 14) {
            if store.quotas.isEmpty && store.state == .loading {
                LoadingCard()
            } else {
                ForEach(store.quotas) { quota in
                    ServiceQuotaCard(snapshot: quota)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(let message) = store.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            HStack {
                Label("read-only local data", systemImage: "lock.shield")
                Spacer()
                Text("⌘ prototype")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

struct ServiceQuotaCard: View {
    let snapshot: QuotaSnapshot

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top) {
                HStack(spacing: 12) {
                    ServiceOrb(snapshot: snapshot)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.serviceName)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(accountLine)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(snapshot.source)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
            }

            HStack(alignment: .lastTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(snapshot.fiveHourRemaining.rounded()))%")
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                        .foregroundStyle(QuotaGradient(remaining: snapshot.fiveHourRemaining).linear)
                        .monospacedDigit()
                    Text("5-hour remaining")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Label("reset \(snapshot.fiveHourReset)", systemImage: "clock")
                    Label("weekly reset \(snapshot.weeklyReset)", systemImage: "calendar")
                    if let overage = snapshot.overage { Label(overage, systemImage: "creditcard") }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            VStack(spacing: 12) {
                MetricProgressRow(label: "5H", remaining: snapshot.fiveHourRemaining)
                MetricProgressRow(label: "WEEK", remaining: snapshot.weeklyRemaining)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(cardGlow.opacity(0.18))
                        .blur(radius: 20)
                        .offset(x: 28, y: -28)
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: shadowColor.opacity(0.26), radius: 22, x: 0, y: 14)
    }

    private var accountLine: String {
        [snapshot.accountName, snapshot.planName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var cardGlow: LinearGradient {
        if snapshot.isClaude {
            return LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [.cyan, .blue, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var shadowColor: Color {
        snapshot.isClaude ? .orange : .cyan
    }
}

struct MetricProgressRow: View {
    let label: String
    let remaining: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            GradientProgressBar(remaining: remaining)
            Text("\(Int(remaining.rounded()))%")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }
}

struct GradientProgressBar: View {
    let remaining: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.13))
                    .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
                Capsule()
                    .fill(QuotaGradient(remaining: remaining).linear)
                    .frame(width: max(8, geo.size.width * remaining / 100))
                    .shadow(color: QuotaGradient(remaining: remaining).dominant.opacity(0.85), radius: 10, x: 0, y: 0)
            }
        }
        .frame(height: 10)
    }
}

struct ServiceOrb: View {
    let snapshot: QuotaSnapshot

    var body: some View {
        ZStack {
            Circle()
                .fill(QuotaGradient(remaining: snapshot.fiveHourRemaining).linear)
                .shadow(color: QuotaGradient(remaining: snapshot.fiveHourRemaining).dominant.opacity(0.7), radius: 12)
            Image(systemName: snapshot.isClaude ? "sparkle" : "circle.hexagongrid.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
    }
}

struct LoadingCard: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Loading quota…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
    }
}

struct StatusPill: View {
    let state: QuotaLoadState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private var label: String {
        switch state {
        case .idle: "IDLE"
        case .loading: "SYNC"
        case .loaded: "LIVE"
        case .failed: "CACHE"
        }
    }

    private var color: Color {
        switch state {
        case .idle: .gray
        case .loading: .blue
        case .loaded: .green
        case .failed: .orange
        }
    }
}

struct GlassBackdrop: View {
    let animate: Bool

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            LinearGradient(
                colors: [
                    Color.black.opacity(0.26),
                    Color(red: 0.05, green: 0.08, blue: 0.15).opacity(0.34),
                    Color.black.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(.cyan.opacity(0.26))
                .frame(width: 210, height: 210)
                .blur(radius: 56)
                .offset(x: animate ? -140 : -115, y: animate ? -220 : -190)
            Circle()
                .fill(.purple.opacity(0.25))
                .frame(width: 230, height: 230)
                .blur(radius: 62)
                .offset(x: animate ? 150 : 120, y: animate ? -90 : -120)
            Circle()
                .fill(.orange.opacity(0.18))
                .frame(width: 260, height: 260)
                .blur(radius: 72)
                .offset(x: 150, y: 260)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: animate)
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct QuotaGradient {
    let remaining: Double

    var colors: [Color] {
        switch remaining {
        case 80...100: [.green, .mint, .cyan]
        case 50..<80: [.cyan, .blue, .purple]
        case 20..<50: [.yellow, .orange]
        default: [.pink, .red, .orange]
        }
    }

    var linear: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    var dominant: Color { colors.first ?? .cyan }
}

struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? 0.20 : 0.10))
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

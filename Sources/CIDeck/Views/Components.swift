import SwiftUI

/// Status glyph for a run. Spins continuously while the run is active.
@MainActor
struct StatusIcon: View {
    let state: RunState
    var size: CGFloat = 13

    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(state.tint)
            .rotationEffect(.degrees(state == .running ? angle : 0))
            .onAppear { startSpinningIfNeeded() }
            .onChange(of: state) { _ in startSpinningIfNeeded() }
            .accessibilityLabel(state.label)
    }

    private func startSpinningIfNeeded() {
        guard state == .running else {
            angle = 0
            return
        }
        angle = 0
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

/// Slim determinate bar used for in-flight runs.
struct RunProgressBar: View {
    /// `nil` renders an indeterminate shimmer instead of a fill.
    let value: Double?
    var tint: Color = .blue

    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                if let value {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, value)))))
                        .animation(.easeInOut(duration: 0.35), value: value)
                } else {
                    Capsule()
                        .fill(tint.opacity(0.7))
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                                phase = 1.0
                            }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}

/// Small rounded label used for branch / event chips.
struct Chip: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 8, weight: .semibold))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Borderless toolbar-style button used in the popover header.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.10) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Centered placeholder for empty / unconfigured states.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
    }
}

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

/// Slim bar for in-flight runs. Given segments it splits into one cell per step
/// (or per job), the way GitHub renders a run's progress; otherwise it falls back
/// to a single continuous fill.
struct RunProgressBar: View {
    /// `nil` renders an indeterminate shimmer instead of a fill.
    let value: Double?
    /// One cell per unit of work. Empty or single-element means a plain bar.
    var segments: [ProgressSegment] = []
    var tint: Color = .blue

    /// Beyond this many cells the gaps eat the bar, so a plain fill reads better.
    private static let maxSegments = 40

    var body: some View {
        if segments.count > 1, segments.count <= Self.maxSegments {
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    ProgressSegmentCell(state: segment.state, tint: tint)
                }
            }
            .frame(height: 5)
        } else {
            ContinuousProgressBar(value: value, tint: tint)
        }
    }
}

/// One cell of a segmented bar. The step being executed right now breathes so the
/// bar still reads as live even while no cell has flipped.
private struct ProgressSegmentCell: View {
    let state: RunState
    let tint: Color

    @State private var isDimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(fill)
            .opacity(state == .running && isDimmed ? 0.4 : 1)
            .frame(maxWidth: .infinity)
            .onAppear { startPulsingIfNeeded() }
            .onChange(of: state) { _ in startPulsingIfNeeded() }
    }

    private var fill: Color {
        switch state {
        case .success, .running:          return tint
        case .failure:                    return .red
        case .cancelled, .skipped,
             .neutral:                    return Color.primary.opacity(0.22)
        case .queued, .waiting:           return Color.primary.opacity(0.10)
        }
    }

    private func startPulsingIfNeeded() {
        guard state == .running else {
            isDimmed = false
            return
        }
        isDimmed = false
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            isDimmed = true
        }
    }
}

/// The unsegmented bar, used before GitHub reports any steps.
private struct ContinuousProgressBar: View {
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
        .frame(height: 5)
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
    /// Side of the square hit area; the glyph scales with it.
    var size: CGFloat = 22
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.55, weight: .medium))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
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

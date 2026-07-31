import SwiftUI

/// The menu bar extra itself.
///
/// macOS renders status item images as template art, so colour alone can't carry
/// meaning here — each state also gets a distinct SF Symbol shape, plus a count
/// badge when more than one run needs attention.
@MainActor
struct MenuBarLabel: View {
    let status: AggregateStatus

    @State private var angle: Double = 0

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.symbol)
                .rotationEffect(.degrees(isRunning ? angle : 0))
            if let badge = status.badge {
                Text(badge).font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(status.tint)
        .onAppear { spinIfNeeded() }
        .onChange(of: status) { _ in spinIfNeeded() }
    }

    private var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private func spinIfNeeded() {
        guard isRunning else {
            angle = 0
            return
        }
        angle = 0
        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

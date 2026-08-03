import SwiftUI

/// The menu bar extra itself: CIDeck's own "CI" mark, tinted by state.
///
/// macOS renders status item images as template art, so colour alone can't carry
/// meaning here — the mark's arc spins while runs are in flight, other states add a
/// distinct SF Symbol beside it, plus a count badge when more than one run needs
/// attention.
@MainActor
struct MenuBarLabel: View {
    let status: AggregateStatus

    @State private var angle: Double = 0

    var body: some View {
        HStack(spacing: 2.5) {
            CIMark(spin: isRunning ? angle : 0)
            if let symbol = status.accessorySymbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
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

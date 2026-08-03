import SwiftUI

/// CIDeck's own status item glyph: an open arc for the "C" and a rounded bar for
/// the "I".
///
/// Drawn as vectors on a 16×16 grid rather than set in a font — at menu bar size a
/// real "CI" in text renders muddy, and vectors let the arc double as a spinner
/// while runs are in flight.
struct CIMark: View {
    /// Rotation applied to the arc only; the bar stays upright so the mark still
    /// reads as "CI" mid-spin.
    var spin: Double = 0

    var body: some View {
        ZStack {
            CIArc()
                .rotationEffect(.degrees(spin), anchor: CIMarkGrid.arcAnchor)
            CIBar()
        }
        .frame(width: CIMarkGrid.unit, height: CIMarkGrid.unit)
    }
}

/// Shared geometry so the arc and the bar stay in proportion at any size.
private enum CIMarkGrid {
    /// Everything below is expressed in points on a 16×16 grid.
    static let unit: CGFloat = 16
    static let stroke: CGFloat = 2.15
    /// Centres given the ink spans arc-left (arcCenterX - radius - stroke/2) to
    /// bar-right (barCenterX + stroke/2) — i.e. ~13pt of glyph on the 16pt grid.
    static let arcCenterX: CGFloat = 6.9
    static let arcRadius: CGFloat = 4.3
    static let barCenterX: CGFloat = 13.4
    static let barHeight: CGFloat = 10.2

    static let arcAnchor = UnitPoint(x: arcCenterX / unit, y: 0.5)

    /// Scale factor from the design grid to whatever `rect` we're handed.
    static func scale(_ rect: CGRect) -> CGFloat { min(rect.width, rect.height) / unit }
}

/// The "C": a 270° arc with the gap facing right. Returned pre-stroked so the
/// weight scales with the mark instead of staying pinned to 16pt.
private struct CIArc: Shape {
    func path(in rect: CGRect) -> Path {
        let s = CIMarkGrid.scale(rect)
        var path = Path()
        path.addArc(center: CGPoint(x: rect.minX + CIMarkGrid.arcCenterX * s, y: rect.midY),
                    radius: CIMarkGrid.arcRadius * s,
                    startAngle: .degrees(45),
                    endAngle: .degrees(315),
                    clockwise: false)
        return path.strokedPath(StrokeStyle(lineWidth: CIMarkGrid.stroke * s, lineCap: .round))
    }
}

/// The "I": a capsule bar matching the arc's stroke weight.
private struct CIBar: Shape {
    func path(in rect: CGRect) -> Path {
        let s = CIMarkGrid.scale(rect)
        let width = CIMarkGrid.stroke * s
        let height = CIMarkGrid.barHeight * s
        let bar = CGRect(x: rect.minX + CIMarkGrid.barCenterX * s - width / 2,
                         y: rect.midY - height / 2,
                         width: width,
                         height: height)
        return Path(roundedRect: bar, cornerRadius: width / 2)
    }
}

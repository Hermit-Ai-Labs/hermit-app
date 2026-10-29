import SwiftUI

/// The Hermit mark: a golden-ratio rectangle with its spiral. Drawn from the brand SVG (viewBox 225 432 1150 735).
public struct HermitMark: View {
    var color: Color
    var height: CGFloat
    public init(color: Color = Theme.accent, height: CGFloat = 18) { self.color = color; self.height = height }

    public var body: some View {
        MarkShape()
            .stroke(color, style: StrokeStyle(lineWidth: max(1.2, height * 44 / 735), lineCap: .round, lineJoin: .round))
            .frame(width: height * 1150 / 735, height: height)
            .accessibilityLabel("Hermit")
    }
}

struct MarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 1150, sy = rect.height / 735
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - 225) * sx, y: rect.minY + (y - 432) * sy) }
        var path = Path()
        path.addRect(CGRect(origin: p(255, 462), size: CGSize(width: 1090 * sx, height: 675 * sy)))
        for (a, b) in [((928.0, 462.0), (928.0, 1137.0)), ((928, 880), (1345, 880)), ((1088, 880), (1088, 1137)), ((928, 978), (1088, 978))] {
            path.move(to: p(a.0, a.1)); path.addLine(to: p(b.0, b.1))
        }
        // the spiral: five quarter arcs, angles in degrees with y pointing down
        let arcs: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (928, 1137, 674, 180, 270), (928, 880, 417.5, 270, 360), (1088, 880, 257, 0, 90),
            (1088, 978, 159.5, 90, 180), (1028, 978, 99, 180, 270),
        ]
        for (i, a) in arcs.enumerated() {
            for k in 0...24 {
                let t = (a.3 + (a.4 - a.3) * CGFloat(k) / 24) * .pi / 180
                let pt = p(a.0 + a.2 * cos(t), a.1 + a.2 * sin(t))
                if i == 0 && k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        return path
    }
}

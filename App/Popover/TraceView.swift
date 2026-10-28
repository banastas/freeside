import SwiftUI

/// A history line graph. With `mirror`, `values` rise above the midline and
/// `mirror` hangs below it (used for download/upload).
struct TraceView: View {
    var values: [Double]
    /// The value drawn at full height.
    var scale: Double = 1
    var color: Color
    var mirror: [Double]? = nil
    var mirrorColor: Color = .secondary

    var body: some View {
        Canvas { context, size in
            let full = CGRect(origin: .zero, size: size)
            if let mirror {
                let (top, bottom) = full.divided(atDistance: size.height / 2, from: .minYEdge)
                plot(values, in: top, rising: true, color: color, context: &context)
                plot(mirror, in: bottom, rising: false, color: mirrorColor, context: &context)
                baseline(at: top.maxY, width: size.width, context: &context)
            } else {
                plot(values, in: full, rising: true, color: color, context: &context)
                baseline(at: full.maxY - 0.5, width: size.width, context: &context)
            }
        }
        .accessibilityHidden(true)
    }

    private func plot(_ values: [Double], in rect: CGRect, rising: Bool, color: Color, context: inout GraphicsContext) {
        guard values.count > 1, scale > 0 else { return }
        let step = rect.width / CGFloat(values.count - 1)
        let base = rising ? rect.maxY : rect.minY
        let points = values.enumerated().map { index, value in
            let height = CGFloat(max(0, min(1, value / scale))) * (rect.height - 1)
            return CGPoint(x: rect.minX + CGFloat(index) * step, y: rising ? base - height : base + height)
        }

        var line = Path()
        line.addLines(points)

        var area = line
        area.addLine(to: CGPoint(x: rect.maxX, y: base))
        area.addLine(to: CGPoint(x: rect.minX, y: base))
        area.closeSubpath()

        context.fill(area, with: .linearGradient(
            Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: rising ? rect.minY : rect.maxY),
            endPoint: CGPoint(x: 0, y: base)
        ))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    private func baseline(at y: CGFloat, width: CGFloat, context: inout GraphicsContext) {
        context.fill(Path(CGRect(x: 0, y: y, width: width, height: 0.5)), with: .color(.secondary.opacity(0.4)))
    }
}

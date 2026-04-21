import SwiftUI

struct TopDownTrajectoryView: View {
    let points: [SIMD2<Float>]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.07, green: 0.08, blue: 0.10), Color(red: 0.03, green: 0.04, blue: 0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                grid(in: geometry.size)

                if points.count >= 2 {
                    pathLayer(in: geometry.size)
                }

                if let firstPoint = projectedPoints(in: geometry.size).first {
                    Circle()
                        .fill(Color.mint)
                        .frame(width: 14, height: 14)
                        .position(firstPoint)
                }

                if let lastPoint = projectedPoints(in: geometry.size).last {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.8), lineWidth: 2)
                        )
                        .position(lastPoint)
                }

                Crosshair()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    .frame(width: 24, height: 24)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private func pathLayer(in size: CGSize) -> some View {
        let projected = projectedPoints(in: size)

        return Canvas { context, _ in
            guard projected.count >= 2 else { return }

            var trail = Path()
            trail.addLines(projected)

            context.stroke(
                trail,
                with: .linearGradient(
                    Gradient(colors: [Color.mint, Color.cyan, Color.yellow]),
                    startPoint: projected.first ?? .zero,
                    endPoint: projected.last ?? .zero
                ),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func grid(in size: CGSize) -> some View {
        Canvas { context, _ in
            let majorSpacing: CGFloat = 80
            let minorSpacing: CGFloat = 20

            func drawGrid(spacing: CGFloat, color: Color, lineWidth: CGFloat) {
                var grid = Path()

                stride(from: CGFloat(0), through: size.width, by: spacing).forEach { x in
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }

                stride(from: CGFloat(0), through: size.height, by: spacing).forEach { y in
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }

                context.stroke(grid, with: .color(color), style: StrokeStyle(lineWidth: lineWidth))
            }

            drawGrid(spacing: minorSpacing, color: .white.opacity(0.05), lineWidth: 0.5)
            drawGrid(spacing: majorSpacing, color: .white.opacity(0.10), lineWidth: 1)
        }
    }

    private func projectedPoints(in size: CGSize) -> [CGPoint] {
        guard !points.isEmpty else { return [] }

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0

        let spanX = CGFloat(max(maxX - minX, 0.2))
        let spanY = CGFloat(max(maxY - minY, 0.2))
        let drawableWidth = max(size.width - 56, 1)
        let drawableHeight = max(size.height - 56, 1)
        let scale = min(drawableWidth / spanX, drawableHeight / spanY)

        let contentWidth = spanX * scale
        let contentHeight = spanY * scale
        let originX = (size.width - contentWidth) / 2
        let originY = (size.height - contentHeight) / 2

        return points.map { point in
            let normalizedX = CGFloat(point.x - minX) * scale
            let normalizedY = CGFloat(point.y - minY) * scale

            return CGPoint(
                x: originX + normalizedX,
                y: size.height - (originY + normalizedY)
            )
        }
    }
}

private struct Crosshair: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

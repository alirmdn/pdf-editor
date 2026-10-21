import SwiftUI

/// The app's mark: a red page with a folded corner, text lines and a pencil, drawn in SwiftUI so
/// it is crisp at any size. `animating` makes it breathe and the pencil write, for loading.
struct LogoMark: View {
    var size: CGFloat = 120
    var animating = false
    @State private var phase = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color(white: 0.11))
                .frame(width: size, height: size)
            Page()
                .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.30, blue: 0.32), Color(red: 0.78, green: 0.16, blue: 0.20)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.46, height: size * 0.58)
                .overlay(alignment: .topTrailing) {
                    Triangle()
                        .fill(Color(red: 1.0, green: 0.72, blue: 0.74))
                        .frame(width: size * 0.15, height: size * 0.15)
                }
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: size * 0.045) {
                        ForEach(0..<3) { i in
                            Capsule()
                                .fill(Color.white.opacity(0.92))
                                .frame(width: size * (i == 2 ? 0.12 : 0.2), height: size * 0.035)
                        }
                    }
                    .padding(.leading, size * 0.07)
                    .offset(y: -size * 0.02)
                }
            Image(systemName: "pencil")
                .font(.system(size: size * 0.24, weight: .heavy))
                .foregroundStyle(.white)
                .offset(x: size * 0.12 + (animating && phase ? size * 0.04 : 0), y: size * 0.1 + (animating && phase ? -size * 0.03 : 0))
        }
        .scaleEffect(animating && phase ? 1.06 : 1.0)
        .shadow(color: Color(red: 0.86, green: 0.24, blue: 0.26).opacity(animating && phase ? 0.55 : 0.15), radius: size * 0.18)
        .onAppear {
            guard animating else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
        }
        .accessibilityHidden(true)
    }

    /// A page outline with the top-right corner cut for the fold.
    private struct Page: Shape {
        func path(in r: CGRect) -> Path {
            let fold = r.width * 0.33
            var p = Path()
            p.move(to: CGPoint(x: r.minX + r.width * 0.08, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.width * 0.08))
            p.addQuadCurve(to: CGPoint(x: r.maxX - r.width * 0.08, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.08, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - r.width * 0.08), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.width * 0.08))
            p.addQuadCurve(to: CGPoint(x: r.minX + r.width * 0.08, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.closeSubpath()
            return p
        }
    }

    private struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}

/// Shown while the app starts: the animated logo on black, the same colours as the launch screen.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                LogoMark(size: 128, animating: true)
                Text("PDF Editor")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

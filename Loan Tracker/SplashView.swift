import SwiftUI

/// Splash with three mountain layers + a rupee that flies to the toolbar
/// logo's actual position (captured via PreferenceKey, no hardcoded coords).
struct SplashView: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Read by SplashGate from the surrounding HomeView toolbar.
    let landingRect: CGRect?
    let isExiting: Bool

    @State private var rupeeOpacity: Double = 0
    @State private var rupeeScale: CGFloat = 0.4
    @State private var mountainReveal: CGFloat = 0
    @State private var horizontalProgress: CGFloat = 0
    @State private var verticalProgress: CGFloat = 0

    private var background: Color { colorScheme == .dark ? .black : Color(white: 0.97) }
    private var foreground: Color { colorScheme == .dark ? .white : .black }
    private var mountainBack: Color   { colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.90) }
    private var mountainMiddle: Color { colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.80) }
    private var mountainFront: Color  { colorScheme == .dark ? Color(white: 0.30) : Color(white: 0.70) }
    private var strokeBack: Color    { foreground.opacity(colorScheme == .dark ? 0.20 : 0.18) }
    private var strokeMiddle: Color  { foreground.opacity(colorScheme == .dark ? 0.30 : 0.26) }
    private var strokeFront: Color   { foreground.opacity(colorScheme == .dark ? 0.40 : 0.35) }

    /// Starting rupee size (pt at scale 1.0).
    private let initialFontSize: CGFloat = 280

    /// Target rupee size derived from the captured landing rect.
    /// Falls back to 22pt if no anchor was published.
    private var targetFontSize: CGFloat {
        guard let rect = landingRect, rect.height > 0 else { return 22 }
        // Toolbar icons render glyphs at about 60% of the row height.
        // For a Text with this font, that's a good visual match.
        return max(18, min(36, rect.height * 0.85))
    }

    var body: some View {
        GeometryReader { screen in
            ZStack {
                background.ignoresSafeArea()

                ZStack {
                    MountainShape(layer: .back).fill(mountainBack)
                        .overlay { MountainShape(layer: .back, closed: false).stroke(strokeBack, lineWidth: 1.5) }
                    MountainShape(layer: .middle).fill(mountainMiddle)
                        .overlay { MountainShape(layer: .middle, closed: false).stroke(strokeMiddle, lineWidth: 1.5) }
                    MountainShape(layer: .front).fill(mountainFront)
                        .overlay { MountainShape(layer: .front, closed: false).stroke(strokeFront, lineWidth: 1.5) }
                }
                .frame(width: screen.size.width, height: screen.size.height)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: screen.size.width * mountainReveal)
                }
                .opacity(isExiting ? 0 : 1)
                .animation(.easeOut(duration: 0.4), value: isExiting)

                Text("₹")
                    .font(.custom("PlayfairDisplayRoman-Bold", size: initialFontSize))
                    .foregroundStyle(foreground)
                    .opacity(rupeeOpacity)
                    .scaleEffect(scale, anchor: .center)
                    .position(position(in: screen.size))
            }
        }
        .ignoresSafeArea()
        .onAppear { runIntro() }
        .onChange(of: isExiting) { _, exiting in
            if exiting { runExit() }
        }
    }

    /// Smooth scale interpolation tied to the further-along axis so visual
    /// size lands at the same moment as position.
    private var scale: CGFloat {
        let progress = max(horizontalProgress, verticalProgress)
        let endScale = targetFontSize / initialFontSize
        return rupeeScale + (endScale - rupeeScale) * progress
    }

    private func position(in size: CGSize) -> CGPoint {
        let startX = size.width / 2
        let startY = size.height / 2

        let endX: CGFloat
        let endY: CGFloat
        if let rect = landingRect {
            endX = rect.midX
            endY = rect.midY
        } else {
            endX = 28; endY = 60   // safe fallback if anchor never published
        }

        let x = startX + (endX - startX) * horizontalProgress
        let y = startY + (endY - startY) * verticalProgress
        return CGPoint(x: x, y: y)
    }

    private func runIntro() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.58)) {
            rupeeOpacity = 1.0
            rupeeScale = 1.0
        }
        withAnimation(.easeInOut(duration: 0.75).delay(0.5)) {
            mountainReveal = 1.0
        }
    }

    private func runExit() {
        // Vertical leads — rupee lifts toward the toolbar first
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            verticalProgress = 1.0
        }
        // Horizontal follows ~0.1s later, creating the arc
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.1)) {
            horizontalProgress = 1.0
        }
    }
}

// MARK: - Mountain peak shape

private struct MountainShape: Shape {
    enum Layer { case back, middle, front }
    let layer: Layer
    var closed: Bool = true

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        let peaks: [(CGFloat, CGFloat)]
        switch layer {
        case .back:
            peaks = [(0.00, 0.20), (0.35, 0.35), (0.75, 0.40), (1.00, 0.60)]
        case .middle:
            peaks = [(0.00, 0.40), (0.25, 0.52), (0.55, 0.50), (0.75, 0.65), (1.00, 0.75)]
        case .front:
            peaks = [(0.00, 0.78), (0.25, 0.80), (0.55, 0.70), (0.75, 0.78), (1.00, 0.92)]
        }

        if let first = peaks.first {
            p.move(to: CGPoint(x: w * first.0, y: h * first.1))
        }
        for (x, y) in peaks.dropFirst() {
            p.addLine(to: CGPoint(x: w * x, y: h * y))
        }
        if closed {
            if let last = peaks.last {
                p.addLine(to: CGPoint(x: w * last.0, y: h))
            }
            p.addLine(to: CGPoint(x: 0, y: h))
            p.closeSubpath()
        }
        return p
    }
}

/// Gate that:
///  - Hosts the content in a named coordinate space ("splashRoot")
///  - Reads where the toolbar logo lives (via PreferenceKey)
///  - Triggers the rupee's spring flight to that exact position
struct SplashGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var stage: Stage = .splash
    @State private var landingRect: CGRect? = nil

    enum Stage { case splash, exiting, done }

    var body: some View {
        ZStack {
            content()
                .opacity(stage == .done ? 1 : 0)
                .coordinateSpace(name: "splashRoot")
                .onPreferenceChange(LogoAnchorKey.self) { rect in
                    // Capture once. The toolbar logo publishes its frame in
                    // splashRoot's coordinates, ready for the splash to read.
                    if rect != .zero {
                        landingRect = rect
                    }
                }

            if stage != .done {
                SplashView(landingRect: landingRect, isExiting: stage == .exiting)
                    .transition(.opacity)
            }
        }
        .task {
            // Wait briefly so the HomeView lays out and publishes its anchor
            try? await Task.sleep(nanoseconds: 200_000_000)
            // Hold the splash
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            stage = .exiting
            // Let the spring play out before swapping to content
            try? await Task.sleep(nanoseconds: 650_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                stage = .done
            }
        }
    }
}

#Preview("Light") {
    SplashView(landingRect: nil, isExiting: false)
        .preferredColorScheme(.light)
}
#Preview("Dark") {
    SplashView(landingRect: nil, isExiting: false)
        .preferredColorScheme(.dark)
}

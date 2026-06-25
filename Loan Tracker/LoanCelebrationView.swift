import SwiftUI

// MARK: - Loan Closure Celebration

/// Full-screen celebration shown when a loan reaches zero balance.
struct LoanCelebrationView: View {
    let loanName: String
    let totalPaid: Double
    let currencyCode: String
    let onDismiss: () -> Void

    @State private var confettiVisible = false
    @State private var checkmarkScale: CGFloat = 0.3
    @State private var checkmarkOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var statsOpacity: Double = 0

    var body: some View {
        ZStack {
            // Background
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 24) {
                Spacer()

                // Checkmark
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 120, height: 120)
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 160, height: 160)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: confettiVisible)
                }
                .scaleEffect(checkmarkScale)
                .opacity(checkmarkOpacity)

                // Title
                VStack(spacing: 8) {
                    Text("Loan Closed!")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text(loanName)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .opacity(textOpacity)

                // Stats
                VStack(spacing: 12) {
                    HStack {
                        Text("Total Paid")
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text(totalPaid, format: .currency(code: currencyCode).precision(.fractionLength(0)))
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                    .font(.subheadline)
                }
                .padding(20)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 40)
                .opacity(statsOpacity)

                Spacer()

                // Confetti emoji rain
                if confettiVisible {
                    ConfettiView()
                        .frame(height: 200)
                        .allowsHitTesting(false)
                }

                Button {
                    onDismiss()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
                .opacity(statsOpacity)
            }
        }
        .onAppear { runAnimation() }
    }

    private func runAnimation() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) {
            checkmarkScale = 1.0
            checkmarkOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
            textOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.5).delay(0.6)) {
            statsOpacity = 1.0
        }
        withAnimation(.easeInOut.delay(0.4)) {
            confettiVisible = true
        }
    }
}

// MARK: - Confetti View

private struct ConfettiView: View {
    @State private var particles: [(id: Int, x: CGFloat, delay: Double, emoji: String)] = []

    private let emojis = ["🎉", "🎊", "✨", "🥳", "💰", "🏆"]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles, id: \.id) { p in
                    Text(p.emoji)
                        .font(.title)
                        .modifier(FallingModifier(delay: p.delay))
                        .position(x: p.x, y: 0)
                }
            }
            .onAppear {
                particles = (0..<15).map { i in
                    (id: i,
                     x: CGFloat.random(in: 20...(geo.size.width - 20)),
                     delay: Double.random(in: 0...1.5),
                     emoji: emojis.randomElement()!)
                }
            }
        }
    }
}

private struct FallingModifier: ViewModifier {
    let delay: Double
    @State private var offset: CGFloat = -50
    @State private var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeIn(duration: 2.0).delay(delay)) {
                    offset = 250
                    opacity = 0
                }
            }
    }
}

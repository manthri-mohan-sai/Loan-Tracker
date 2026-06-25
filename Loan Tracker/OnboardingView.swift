import SwiftUI

// MARK: - Onboarding

/// Immersive three-screen walkthrough shown on first launch.
/// Dark-themed with animated mock UI that demonstrates each feature.
struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var currentPage = 0
    @State private var pageAppeared: [Bool] = [false, false, false]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AmbientBackground(page: currentPage)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    LoanCardsPage(isActive: pageAppeared[0]).tag(0)
                    SavingsChartPage(isActive: pageAppeared[1]).tag(1)
                    PrivacyPage(isActive: pageAppeared[2]).tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Bottom controls
                VStack(spacing: 20) {
                    // Custom page indicator
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule()
                                .fill(.white.opacity(i == currentPage ? 1.0 : 0.25))
                                .frame(width: i == currentPage ? 24 : 8, height: 8)
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: currentPage)

                    Button {
                        if currentPage < 2 {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                currentPage += 1
                            }
                        } else {
                            withAnimation { isComplete = true }
                        }
                    } label: {
                        Text(currentPage < 2 ? "Continue" : "Get Started")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.white)
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    if currentPage < 2 {
                        Button("Skip") { withAnimation { isComplete = true } }
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                    } else {
                        Color.clear.frame(height: 20)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: currentPage) { _, newPage in
            if !pageAppeared[newPage] {
                pageAppeared[newPage] = true
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            pageAppeared[0] = true
        }
    }
}

// MARK: - Ambient Background

/// Radial gradient blobs that shift hue per page. Uses gradients instead of
/// blur filters for smooth 60fps color transitions during page swipes.
private struct AmbientBackground: View {
    let page: Int

    private var blob1: Color {
        [Color.cyan, .purple, .orange][page]
    }
    private var blob2: Color {
        [Color.blue, .pink, .yellow][page]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [blob1.opacity(0.55), .clear],
                        center: .center, startRadius: 20, endRadius: 180
                    ))
                    .frame(width: 360, height: 360)
                    .offset(x: -geo.size.width * 0.2, y: -geo.size.height * 0.18)

                Circle()
                    .fill(RadialGradient(
                        colors: [blob2.opacity(0.45), .clear],
                        center: .center, startRadius: 15, endRadius: 160
                    ))
                    .frame(width: 320, height: 320)
                    .offset(x: geo.size.width * 0.25, y: geo.size.height * 0.22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.8), value: page)
        .drawingGroup() // Flatten into single GPU layer
    }
}

// MARK: - Page 1: Every Loan, One Glance

private struct LoanCardsPage: View {
    let isActive: Bool

    @State private var cardVisible = [false, false, false]
    @State private var progressFill: [CGFloat] = [0, 0, 0]
    @State private var titleVisible = false

    private struct MockLoan {
        let icon: String, name: String, bank: String, amount: String
        let progress: CGFloat, color: Color
    }

    private let loans: [MockLoan] = [
        MockLoan(icon: "house.fill", name: "Home Loan", bank: "SBI", amount: "$245,000", progress: 0.35, color: Color(red: 0.35, green: 0.55, blue: 1.0)),
        MockLoan(icon: "car.fill", name: "Car Loan", bank: "Chase", amount: "$18,400", progress: 0.62, color: Color(red: 0.2, green: 0.85, blue: 0.65)),
        MockLoan(icon: "graduationcap.fill", name: "Education", bank: "Wells Fargo", amount: "$52,000", progress: 0.15, color: Color(red: 1.0, green: 0.6, blue: 0.25)),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Title
            VStack(spacing: 12) {
                Text("Every Loan, One Glance")
                    .font(.custom("PlayfairDisplayRoman-Bold", size: 28))
                    .foregroundStyle(.white)

                Text("Home, car, personal, education — track them all in one beautiful dashboard.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .opacity(titleVisible ? 1 : 0)
            .offset(y: titleVisible ? 0 : 20)

            Spacer().frame(height: 40)

            // Mock cards
            VStack(spacing: 14) {
                ForEach(Array(loans.enumerated()), id: \.offset) { i, loan in
                    MockLoanCard(
                        icon: loan.icon,
                        name: loan.name,
                        bank: loan.bank,
                        amount: loan.amount,
                        progress: progressFill[i],
                        accentColor: loan.color
                    )
                    .opacity(cardVisible[i] ? 1 : 0)
                    .offset(y: cardVisible[i] ? 0 : 24)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
        .onChange(of: isActive) { _, active in
            if active { runEntrance() }
        }
    }

    private func runEntrance() {
        withAnimation(.easeOut(duration: 0.6)) { titleVisible = true }

        for i in 0..<3 {
            let stagger = Double(i) * 0.12
            withAnimation(.easeOut(duration: 0.55).delay(0.15 + stagger)) {
                cardVisible[i] = true
            }
            withAnimation(.easeOut(duration: 0.7).delay(0.5 + stagger)) {
                progressFill[i] = loans[i].progress
            }
        }
    }
}

// MARK: - Mock Loan Card

private struct MockLoanCard: View {
    let icon: String, name: String, bank: String, amount: String
    let progress: CGFloat
    let accentColor: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(accentColor)
                .frame(width: 38, height: 38)
                .background(accentColor.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                    Text(bank)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Text(amount)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                }

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(accentColor)
                        .scaleEffect(x: progress, y: 1, anchor: .leading)
                }
                .frame(height: 5)
                .clipShape(Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Page 2: See What Saves You Money

private struct SavingsChartPage: View {
    let isActive: Bool

    @State private var titleVisible = false
    @State private var grayTrim: CGFloat = 0
    @State private var greenTrim: CGFloat = 0
    @State private var fillOpacity: Double = 0
    @State private var badgeVisible = false
    @State private var labelsVisible = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Text("See What Saves\nYou Money")
                    .font(.custom("PlayfairDisplayRoman-Bold", size: 28))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Visualize how prepayments shorten your loan and cut interest costs.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .opacity(titleVisible ? 1 : 0)
            .offset(y: titleVisible ? 0 : 20)

            Spacer().frame(height: 40)

            // Chart
            ZStack(alignment: .topTrailing) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height

                    ZStack {
                        // Axes
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: 0))
                            p.addLine(to: CGPoint(x: 0, y: h))
                            p.addLine(to: CGPoint(x: w, y: h))
                        }
                        .stroke(.white.opacity(0.15), lineWidth: 1)

                        // Savings fill
                        SavingsAreaShape(chartWidth: w, chartHeight: h)
                            .fill(Color.green.opacity(0.1))
                            .opacity(fillOpacity)

                        // Gray curve (without prepayments)
                        BalanceCurve(chartWidth: w, chartHeight: h, endFraction: 1.0, exponent: 3.2)
                            .trim(from: 0, to: grayTrim)
                            .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                        // Green curve (with prepayments)
                        BalanceCurve(chartWidth: w, chartHeight: h, endFraction: 0.6, exponent: 2.5)
                            .trim(from: 0, to: greenTrim)
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                        // Labels
                        if labelsVisible {
                            Text("20 yrs")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.3))
                                .position(x: w - 22, y: h + 16)

                            Text("12 yrs")
                                .font(.caption2)
                                .foregroundStyle(.green.opacity(0.7))
                                .position(x: w * 0.6, y: h + 16)
                        }
                    }
                }
                .frame(height: 200)
                .padding(.horizontal, 32)

                // Savings badge
                if badgeVisible {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.green)
                        Text("Save $47,200")
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.2))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.green.opacity(0.3), lineWidth: 1))
                    .transition(.scale.combined(with: .opacity))
                    .padding(.trailing, 36)
                    .padding(.top, 8)
                }
            }

            Spacer().frame(height: 20)

            // Legend
            HStack(spacing: 20) {
                legendDot(color: .white.opacity(0.35), label: "Without prepayments")
                legendDot(color: .green, label: "With prepayments")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
            .opacity(labelsVisible ? 1 : 0)

            Spacer()
            Spacer()
        }
        .onChange(of: isActive) { _, active in
            if active { runEntrance() }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func runEntrance() {
        withAnimation(.easeOut(duration: 0.6)) { titleVisible = true }
        withAnimation(.easeInOut(duration: 1.4).delay(0.3)) { grayTrim = 1.0 }
        withAnimation(.easeInOut(duration: 1.0).delay(0.8)) { greenTrim = 1.0 }
        withAnimation(.easeOut(duration: 0.5).delay(1.5)) { labelsVisible = true }
        withAnimation(.easeInOut(duration: 0.7).delay(1.6)) { fillOpacity = 1.0 }
        withAnimation(.easeOut(duration: 0.4).delay(2.0)) { badgeVisible = true }
    }
}

// MARK: - Chart Shapes

/// Declining balance curve using power-function approximation: B(t) = (1-t)^n
private struct BalanceCurve: Shape {
    let chartWidth: CGFloat
    let chartHeight: CGFloat
    let endFraction: CGFloat
    let exponent: CGFloat

    func path(in rect: CGRect) -> Path {
        let steps = 60
        var p = Path()
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = t * chartWidth * endFraction
            let balance = pow(1.0 - t, exponent)
            let y = (1.0 - balance) * chartHeight
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

/// Filled area between the two balance curves — the savings region.
private struct SavingsAreaShape: Shape {
    let chartWidth: CGFloat
    let chartHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let steps = 60
        let greenEnd: CGFloat = 0.6
        let greenExp: CGFloat = 2.5
        let grayExp: CGFloat = 3.2
        var p = Path()

        // Forward along green curve
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = t * chartWidth * greenEnd
            let y = (1.0 - pow(1.0 - t, greenExp)) * chartHeight
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }

        // Line down to gray curve endpoint at same x
        let grayBalAtGreenEnd = pow(1.0 - greenEnd, grayExp)
        p.addLine(to: CGPoint(x: chartWidth * greenEnd, y: (1.0 - grayBalAtGreenEnd) * chartHeight))

        // Backward along gray curve
        for i in stride(from: steps, through: 0, by: -1) {
            let t = CGFloat(i) / CGFloat(steps) * greenEnd
            let y = (1.0 - pow(1.0 - t, grayExp)) * chartHeight
            p.addLine(to: CGPoint(x: t * chartWidth, y: y))
        }

        p.closeSubpath()
        return p
    }
}

// MARK: - Page 3: Private by Design

private struct PrivacyPage: View {
    let isActive: Bool

    @State private var titleVisible = false
    @State private var shieldScale: CGFloat = 0.4
    @State private var shieldOpacity: Double = 0
    @State private var ringVisible = [false, false, false]
    @State private var pillVisible = [false, false, false]

    private let features = [
        "Everything stays on your device",
        "Encrypted backups",
        "Face ID protection",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Text("Private by Design")
                    .font(.custom("PlayfairDisplayRoman-Bold", size: 28))
                    .foregroundStyle(.white)

                Text("Your financial data never leaves your device. No servers, no tracking, no compromises.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .opacity(titleVisible ? 1 : 0)
            .offset(y: titleVisible ? 0 : 20)

            Spacer().frame(height: 40)

            // Shield with radiating rings
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(.white.opacity([0.15, 0.10, 0.06][i]), lineWidth: 1.5)
                        .frame(width: CGFloat([100, 150, 200][i]))
                        .scaleEffect(ringVisible[i] ? 1 : 0.5)
                        .opacity(ringVisible[i] ? 1 : 0)
                }

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white)
                    .scaleEffect(shieldScale)
                    .opacity(shieldOpacity)
            }
            .frame(height: 210)

            Spacer().frame(height: 32)

            // Feature pills
            VStack(spacing: 12) {
                ForEach(Array(features.enumerated()), id: \.offset) { i, text in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.08))
                    .clipShape(Capsule())
                    .opacity(pillVisible[i] ? 1 : 0)
                    .offset(x: pillVisible[i] ? 0 : -30)
                }
            }

            Spacer()
            Spacer()
        }
        .onChange(of: isActive) { _, active in
            if active { runEntrance() }
        }
    }

    private func runEntrance() {
        withAnimation(.easeOut(duration: 0.6)) { titleVisible = true }

        // Shield
        withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.2)) {
            shieldScale = 1.0
            shieldOpacity = 1.0
        }

        // Rings radiate outward
        for i in 0..<3 {
            withAnimation(.easeOut(duration: 0.5).delay(0.5 + Double(i) * 0.15)) {
                ringVisible[i] = true
            }
        }

        // Pills slide in
        for i in 0..<3 {
            withAnimation(.easeOut(duration: 0.45).delay(0.9 + Double(i) * 0.12)) {
                pillVisible[i] = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView(isComplete: .constant(false))
}

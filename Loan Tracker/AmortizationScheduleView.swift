import SwiftUI
import Charts

// MARK: - Amortization Schedule View

/// Full month-by-month amortization schedule showing how each EMI splits
/// into principal and interest. Accessible from the loan detail view.
struct AmortizationScheduleView: View {
    let loan: Loan

    private var schedule: [AmortizationRow] {
        loan.amortizationSchedule()
    }

    private var cc: String { loan.currencyCode }

    /// Total interest remaining across the full schedule.
    private var totalInterestRemaining: Double {
        schedule.reduce(0) { $0 + $1.interestComponent }
    }

    /// Total principal remaining across the full schedule.
    private var totalPrincipalRemaining: Double {
        schedule.reduce(0) { $0 + $1.principalComponent }
    }

    var body: some View {
        List {
            // Summary section
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remaining Balance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(loan.remainingBalance, format: .currency(code: cc).precision(.fractionLength(0)))
                            .font(.title3.bold())
                            .monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("EMIs Left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(schedule.count)")
                            .font(.title3.bold())
                    }
                }

                // Principal vs Interest breakdown
                InterestPrincipalBar(
                    principalRemaining: totalPrincipalRemaining,
                    interestRemaining: totalInterestRemaining,
                    currencyCode: cc
                )
            }

            // Stacked area chart showing principal vs interest over time
            if schedule.count > 1 {
                Section("Principal vs Interest Over Time") {
                    PrincipalInterestChart(schedule: schedule, currencyCode: cc)
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }

            // Month-by-month table
            Section("Schedule") {
                // Header row
                HStack {
                    Text("Month")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Principal")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Interest")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Balance")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(schedule) { row in
                    HStack {
                        Text(row.date, format: .dateTime.month(.abbreviated).year(.twoDigits))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.principalComponent, format: .currency(code: cc).precision(.fractionLength(0)))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(row.interestComponent, format: .currency(code: cc).precision(.fractionLength(0)))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(row.closingBalance, format: .currency(code: cc).precision(.fractionLength(0)))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }
        }
        .navigationTitle("Amortization")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Principal vs Interest Horizontal Bar

/// Stacked horizontal bar showing how the remaining cash outflow splits
/// between principal repayment and interest cost.
struct InterestPrincipalBar: View {
    let principalRemaining: Double
    let interestRemaining: Double
    let currencyCode: String

    private var total: Double { principalRemaining + interestRemaining }

    private var principalFraction: Double {
        guard total > 0 else { return 0 }
        return principalRemaining / total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: max(2, geo.size.width * principalFraction))
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: max(2, geo.size.width * (1 - principalFraction)))
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text("Principal")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(principalRemaining, format: .currency(code: currencyCode).precision(.fractionLength(0)))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text("Interest")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(interestRemaining, format: .currency(code: currencyCode).precision(.fractionLength(0)))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Principal vs Interest Area Chart

/// Stacked area chart showing how the principal and interest components
/// of each EMI change over the life of the loan.
struct PrincipalInterestChart: View {
    let schedule: [AmortizationRow]
    let currencyCode: String

    /// Downsample for performance — 40 points is visually smooth.
    private var sampled: [AmortizationRow] {
        guard schedule.count > 40 else { return schedule }
        let step = Double(schedule.count - 1) / 39.0
        return (0..<40).map { i in
            let idx = min(Int((Double(i) * step).rounded()), schedule.count - 1)
            return schedule[idx]
        }
    }

    var body: some View {
        Chart {
            ForEach(sampled) { row in
                AreaMark(
                    x: .value("Month", row.id),
                    y: .value("Amount", row.principalComponent)
                )
                .foregroundStyle(by: .value("Type", "Principal"))
            }

            ForEach(sampled) { row in
                AreaMark(
                    x: .value("Month", row.id),
                    y: .value("Amount", row.interestComponent)
                )
                .foregroundStyle(by: .value("Type", "Interest"))
            }
        }
        .chartForegroundStyleScale([
            "Principal": Color.accentColor.opacity(0.7),
            "Interest": Color.orange.opacity(0.7)
        ])
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let m = value.as(Int.self) {
                        Text("\(m)mo").font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v, format: .currency(code: currencyCode).precision(.fractionLength(0)).notation(.compactName))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartLegend(.visible)
        .padding(.horizontal, 16)
    }
}

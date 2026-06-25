import SwiftUI

// MARK: - Refinance Analyzer

/// Compares current loan terms against a potential refinance offer,
/// showing break-even month, total interest savings, and new EMI.
struct RefinanceAnalyzerView: View {
    let loan: Loan

    @State private var newRatePercent: Double = 0
    @State private var newTenureMonths: Int = 0
    @State private var refinanceFee: Double = 0

    private var cc: String { loan.currencyCode }

    private var currentBalance: Double { loan.remainingBalance }
    private var currentRate: Double { loan.annualInterestRate }
    private var currentEMI: Double { loan.monthlyPayment }
    private var currentMonthsRemaining: Int { loan.estimatedMonthsRemaining ?? 0 }

    private var newRate: Double { newRatePercent / 100.0 }
    private var newMonthlyRate: Double { newRate / 12.0 }

    /// New EMI calculated from current balance + new rate + new tenure.
    private var newEMI: Double? {
        let P = currentBalance
        let r = newMonthlyRate
        let n = Double(newTenureMonths)
        guard P > 0, n > 0 else { return nil }
        if r == 0 { return P / n }
        let factor = pow(1 + r, n)
        guard factor > 1 else { return nil }
        return P * r * factor / (factor - 1)
    }

    /// Total interest under new terms.
    private var newTotalInterest: Double? {
        guard let emi = newEMI else { return nil }
        return emi * Double(newTenureMonths) - currentBalance
    }

    /// Total interest remaining under current terms.
    private var currentTotalInterest: Double {
        currentEMI * Double(currentMonthsRemaining) - currentBalance
    }

    /// Interest saved by refinancing (negative = costs more).
    private var interestSaved: Double? {
        guard let newInterest = newTotalInterest else { return nil }
        return currentTotalInterest - newInterest - refinanceFee
    }

    /// Month at which cumulative savings from lower EMI exceed the refinance fee.
    private var breakEvenMonth: Int? {
        guard let emi = newEMI, emi < currentEMI, refinanceFee > 0 else { return nil }
        let monthlySavings = currentEMI - emi
        return Int(ceil(refinanceFee / monthlySavings))
    }

    var body: some View {
        Form {
            // Current loan summary
            Section("Current Loan") {
                row("Outstanding Balance", currentBalance, currency: true)
                row("Interest Rate", currentRate * 100, suffix: "%")
                row("Monthly EMI", currentEMI, currency: true)
                row("Months Remaining", Double(currentMonthsRemaining))
                row("Remaining Interest", currentTotalInterest, currency: true)
            }

            // New terms input
            Section {
                HStack {
                    Text("New Rate %")
                    Spacer()
                    TextField("", value: $newRatePercent, format: .number.precision(.fractionLength(1...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                }
                HStack {
                    Text("New Tenure (months)")
                    Spacer()
                    TextField("", value: $newTenureMonths, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                }
                HStack {
                    Text("Refinance Fee")
                    Spacer()
                    FormattedAmountField(value: $refinanceFee)
                }
            } header: {
                Text("New Terms")
            } footer: {
                Text("Enter the terms offered by the new lender. Include any processing fees, legal charges, or balance transfer fees.")
            }

            // Results
            if let emi = newEMI, let saved = interestSaved {
                Section("Comparison") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Current EMI")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(currentEMI, format: .currency(code: cc).precision(.fractionLength(0)))
                                .font(.title3.bold())
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("New EMI")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(emi, format: .currency(code: cc).precision(.fractionLength(0)))
                                .font(.title3.bold())
                                .foregroundStyle(emi < currentEMI ? .green : .red)
                        }
                    }

                    HStack {
                        Text("Interest Savings")
                        Spacer()
                        Text(saved, format: .currency(code: cc).precision(.fractionLength(0)))
                            .fontWeight(.bold)
                            .foregroundStyle(saved > 0 ? .green : .red)
                    }

                    if let months = breakEvenMonth {
                        HStack {
                            Text("Break-even")
                            Spacer()
                            Text("\(months) months")
                                .fontWeight(.medium)
                        }
                    }

                    // Verdict
                    if saved > 0 {
                        Label("Refinancing saves you \(saved, format: .currency(code: cc).precision(.fractionLength(0)))",
                              systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.medium))
                    } else {
                        Label("Refinancing costs more — not recommended",
                              systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
        .navigationTitle("Refinance Analyzer")
        .onAppear {
            if newRatePercent == 0 {
                newRatePercent = max(0, currentRate * 100 - 0.5) // Suggest 0.5% lower
            }
            if newTenureMonths == 0 {
                newTenureMonths = currentMonthsRemaining
            }
        }
    }

    private func row(_ label: String, _ value: Double, currency: Bool = false, suffix: String = "") -> some View {
        HStack {
            Text(label)
            Spacer()
            if currency {
                Text(value, format: .currency(code: cc).precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
            } else if !suffix.isEmpty {
                Text("\(value, specifier: "%.2f")\(suffix)")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(Int(value))")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

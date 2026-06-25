import SwiftUI
import SwiftData

// MARK: - Rate Change History

/// Shows the full rate change history for a loan with option to add new entries.
struct RateChangeHistoryView: View {
    let loan: Loan
    @Environment(\.modelContext) private var context
    @State private var showingAddSheet = false

    private var sortedChanges: [RateChange] {
        loan.rateChanges.sorted { $0.effectiveDate > $1.effectiveDate }
    }

    var body: some View {
        List {
            // Current rate card
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current Rate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(loan.annualInterestRate * 100, specifier: "%.2f")%")
                            .font(.title2.bold())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(loan.isFloatingRate ? "Floating" : "Fixed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(loan.monthlyPayment, format: .currency(code: loan.currencyCode).precision(.fractionLength(0)))
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Text("EMI/mo")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // History
            if sortedChanges.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Rate Changes",
                        systemImage: "chart.line.flattrend.xyaxis",
                        description: Text("Rate changes will appear here when you add them or import from documents.")
                    )
                }
            } else {
                Section("History") {
                    ForEach(sortedChanges, id: \.effectiveDate) { change in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(change.newAnnualRate * 100, specifier: "%.2f")%")
                                    .font(.subheadline.bold())
                                if let note = change.note, !note.isEmpty {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(change.effectiveDate, format: .dateTime.day().month(.abbreviated).year())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteChanges)
                }
            }
        }
        .navigationTitle("Rate History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") {
                    showingAddSheet = true
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddRateChangeSheet(loan: loan)
        }
    }

    private func deleteChanges(at offsets: IndexSet) {
        for index in offsets {
            context.delete(sortedChanges[index])
        }
        try? context.save()
        refreshAppState()
    }
}

// MARK: - Add Rate Change Sheet

struct AddRateChangeSheet: View {
    let loan: Loan
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var newRatePercent: Double = 0
    @State private var effectiveDate: Date = .now
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("New Rate %")
                        Spacer()
                        TextField("", value: $newRatePercent, format: .number.precision(.fractionLength(1...2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                    }
                    DatePicker("Effective Date", selection: $effectiveDate, displayedComponents: .date)
                    TextField("Note (e.g. Repo rate cut)", text: $note)
                } footer: {
                    Text("Current rate: \(loan.annualInterestRate * 100, specifier: "%.2f")%")
                }
            }
            .navigationTitle("Add Rate Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(newRatePercent <= 0)
                }
            }
            .onAppear {
                newRatePercent = loan.annualInterestRate * 100
            }
        }
    }

    private func save() {
        let change = RateChange(
            effectiveDate: effectiveDate,
            newAnnualRate: newRatePercent / 100.0,
            note: note.isEmpty ? nil : note
        )
        change.loan = loan
        context.insert(change)

        // Update the loan's current rate to the latest change
        loan.annualInterestRate = newRatePercent / 100.0

        try? context.save()
        refreshAppState()
        dismiss()
    }
}

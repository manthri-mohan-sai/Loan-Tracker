import SwiftUI
import SwiftData

// MARK: - Document Review View

/// Routes to the correct review UI based on the extraction result.
struct DocumentReviewView: View {
    let result: DocumentExtractionResult
    /// When set, the import targets this specific loan.
    var targetLoan: Loan?
    let onDismiss: () -> Void

    @Query(sort: \Loan.createdAt) private var existingLoans: [Loan]
    @Environment(\.modelContext) private var context

    var body: some View {
        switch result.fields {
        case .loanCreation(let fields):
            if let loan = targetLoan {
                // Per-loan import: pre-fill the edit form for this loan
                LoanCreationReviewView(
                    fields: fields,
                    documentType: result.documentType,
                    existingLoan: loan,
                    onDismiss: onDismiss
                )
            } else {
                LoanCreationReviewView(
                    fields: fields,
                    documentType: result.documentType,
                    onDismiss: onDismiss
                )
            }

        case .rateChange(let fields):
            RateChangeReviewView(
                fields: fields,
                existingLoans: targetLoan != nil ? [targetLoan!] : existingLoans,
                context: context,
                preselectedLoan: targetLoan,
                onDismiss: onDismiss
            )

        case .loanStatement(let fields):
            StatementReviewView(
                fields: fields,
                existingLoans: targetLoan != nil ? [targetLoan!] : existingLoans,
                context: context,
                preselectedLoan: targetLoan,
                onDismiss: onDismiss
            )

        case .referenceOnly:
            ReferenceOnlyView(
                documentType: result.documentType,
                markdownText: result.markdownText,
                onDismiss: onDismiss
            )
        }
    }
}

// MARK: - Loan Creation Review

/// For sanction letters, loan agreements, disbursement letters.
/// Pre-fills a LoanFormView with extracted data.
struct LoanCreationReviewView: View {
    let fields: LoanCreationFields
    let documentType: LoanDocumentType
    /// When set, updates this loan instead of creating a new one.
    var existingLoan: Loan?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Document type badge
            documentBadge

            // Pre-filled LoanFormView — edit existing or create new
            if let loan = existingLoan {
                LoanFormView(loan: loan, prefill: LoanPrefill(from: fields))
            } else {
                LoanFormView(prefill: LoanPrefill(from: fields))
            }
        }
    }

    private var documentBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: documentType.sfSymbol)
                .foregroundStyle(.green)
            Text("Detected: \(documentType.displayName)")
                .font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.1))
    }
}

// MARK: - Rate Change Review

/// For rate change and restructuring letters.
/// Lets user pick which loan to apply the rate change to.
struct RateChangeReviewView: View {
    let fields: RateChangeFields
    let existingLoans: [Loan]
    let context: ModelContext
    let onDismiss: () -> Void

    @State private var selectedLoan: Loan?
    @State private var newRate: Double
    @State private var effectiveDate: Date
    @State private var note: String
    @State private var didSave = false

    init(fields: RateChangeFields, existingLoans: [Loan], context: ModelContext, preselectedLoan: Loan? = nil, onDismiss: @escaping () -> Void) {
        self.fields = fields
        self.existingLoans = existingLoans
        self.context = context
        self.onDismiss = onDismiss

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        _newRate = State(initialValue: fields.newRatePercent)
        _effectiveDate = State(initialValue: formatter.date(from: fields.effectiveDate) ?? .now)
        _note = State(initialValue: fields.reason)

        // Use preselected loan if provided, otherwise auto-match by bank name
        if let preselected = preselectedLoan {
            _selectedLoan = State(initialValue: preselected)
        } else {
            let matchedLoan = existingLoans.first {
                !fields.bankName.isEmpty &&
                $0.bankName.localizedCaseInsensitiveContains(fields.bankName)
            }
            _selectedLoan = State(initialValue: matchedLoan)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(.orange)
                        Text("Rate Change Detected")
                            .font(.headline)
                    }
                }

                Section("Apply to Loan") {
                    if existingLoans.isEmpty {
                        Text("No loans found. Add a loan first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Loan", selection: $selectedLoan) {
                            Text("Select a loan…").tag(nil as Loan?)
                            ForEach(existingLoans) { loan in
                                Text(loan.name).tag(loan as Loan?)
                            }
                        }
                    }
                }

                Section("Rate Change Details") {
                    HStack {
                        Text("New Rate")
                        Spacer()
                        TextField("Rate %", value: $newRate, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("%")
                    }

                    DatePicker("Effective Date", selection: $effectiveDate, displayedComponents: .date)

                    if fields.previousRatePercent > 0 {
                        HStack {
                            Text("Previous Rate")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(fields.previousRatePercent, specifier: "%.2f")%")
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextField("Note (optional)", text: $note)
                }

                if didSave {
                    Section {
                        Label("Rate change saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Rate Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { applyRateChange() }
                        .disabled(selectedLoan == nil || newRate <= 0 || didSave)
                }
            }
        }
    }

    private func applyRateChange() {
        guard let loan = selectedLoan else { return }
        let action = DocumentAction.addRateChange(
            loan: loan,
            effectiveDate: effectiveDate,
            newRate: newRate / 100.0,
            note: note.isEmpty ? nil : note
        )
        try? action.execute(context: context)
        refreshAppState()
        didSave = true

        // Auto-dismiss after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            onDismiss()
        }
    }
}

// MARK: - Statement Review

/// For loan statements. Compares extracted balance with tracked balance.
struct StatementReviewView: View {
    let fields: LoanStatementFields
    let existingLoans: [Loan]
    let context: ModelContext
    let onDismiss: () -> Void

    @State private var selectedLoan: Loan?
    @State private var statementBalance: Double
    @State private var didSave = false

    init(fields: LoanStatementFields, existingLoans: [Loan], context: ModelContext, preselectedLoan: Loan? = nil, onDismiss: @escaping () -> Void) {
        self.fields = fields
        self.existingLoans = existingLoans
        self.context = context
        self.onDismiss = onDismiss
        _statementBalance = State(initialValue: fields.outstandingBalance)

        if let preselected = preselectedLoan {
            _selectedLoan = State(initialValue: preselected)
        } else {
            let matchedLoan = existingLoans.first {
                !fields.bankName.isEmpty &&
                $0.bankName.localizedCaseInsensitiveContains(fields.bankName)
            }
            _selectedLoan = State(initialValue: matchedLoan)
        }
    }

    private var trackedBalance: Double? {
        selectedLoan?.remainingBalance
    }

    private var difference: Double? {
        guard let tracked = trackedBalance, statementBalance > 0 else { return nil }
        return statementBalance - tracked
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundStyle(.blue)
                        Text("Statement Detected")
                            .font(.headline)
                    }
                }

                Section("Match to Loan") {
                    if existingLoans.isEmpty {
                        Text("No loans found.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Loan", selection: $selectedLoan) {
                            Text("Select a loan…").tag(nil as Loan?)
                            ForEach(existingLoans) { loan in
                                Text(loan.name).tag(loan as Loan?)
                            }
                        }
                    }
                }

                Section("Balance Comparison") {
                    HStack {
                        Text("Statement Balance")
                        Spacer()
                        TextField("Balance", value: $statementBalance, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }

                    if let tracked = trackedBalance {
                        HStack {
                            Text("Tracked Balance")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(tracked, format: .number.precision(.fractionLength(0)))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let diff = difference {
                        HStack {
                            Text("Difference")
                            Spacer()
                            Text(diff, format: .number.precision(.fractionLength(0)))
                                .foregroundStyle(abs(diff) < 100 ? .green : .orange)
                        }
                    }
                }

                if didSave {
                    Section {
                        Label("Balance updated", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Loan Statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update Balance") { updateBalance() }
                        .disabled(selectedLoan == nil || statementBalance <= 0 || didSave)
                }
            }
        }
    }

    private func updateBalance() {
        guard let loan = selectedLoan else { return }
        let action = DocumentAction.updateBalance(
            loan: loan,
            newBalance: statementBalance,
            asOfDate: .now
        )
        try? action.execute(context: context)
        refreshAppState()
        didSave = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            onDismiss()
        }
    }
}

// MARK: - Reference Only View

/// For document types that don't require data entry
/// (insurance policies, collateral docs, interest certificates).
struct ReferenceOnlyView: View {
    let documentType: LoanDocumentType
    let markdownText: String?
    let onDismiss: () -> Void

    @State private var showingMarkdown = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: documentType.sfSymbol)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text(documentType.displayName)
                    .font(.title3.weight(.semibold))

                Text("This document type is recognized but doesn't contain fields to import automatically. You can use it as a reference.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let markdownText, !markdownText.isEmpty {
                    Button {
                        showingMarkdown = true
                    } label: {
                        Label("View Markdown", systemImage: "doc.plaintext")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()
            }
            .navigationTitle("Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
            .sheet(isPresented: $showingMarkdown) {
                if let markdownText {
                    MarkdownPreviewView(markdownText: markdownText)
                }
            }
        }
    }
}

private struct MarkdownPreviewView: View {
    let markdownText: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(markdownText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            .navigationTitle("Markdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: markdownText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

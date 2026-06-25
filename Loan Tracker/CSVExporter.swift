import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - CSV Export

enum CSVExporter {

    /// Generates a CSV string of all loans and their payments.
    static func generateLoansSummary(loans: [Loan]) -> String {
        var csv = "Loan Name,Bank,Currency,Principal,Interest Rate %,EMI,Tenure (months),Start Date,Outstanding Balance,Total Paid,Rate Type,Prepayment Penalty %\n"

        for loan in loans {
            let row = [
                escaped(loan.name),
                escaped(loan.bankName),
                loan.currencyCode,
                String(format: "%.2f", loan.principal),
                String(format: "%.2f", loan.annualInterestRate * 100),
                String(format: "%.2f", loan.monthlyPayment),
                "\(loan.tenureMonths)",
                iso(loan.startDate),
                String(format: "%.2f", loan.remainingBalance),
                String(format: "%.2f", loan.totalPaid),
                loan.isFloatingRate ? "Floating" : "Fixed",
                String(format: "%.1f", loan.prepaymentPenaltyPercent)
            ].joined(separator: ",")
            csv += row + "\n"
        }
        return csv
    }

    /// Generates a CSV of payment history across all loans.
    static func generatePayments(loans: [Loan]) -> String {
        var csv = "Loan Name,Date,Amount,Type,Note\n"

        let allPayments = loans.flatMap { loan in
            loan.payments.map { (loan: loan, payment: $0) }
        }.sorted { $0.payment.date > $1.payment.date }

        for item in allPayments {
            let row = [
                escaped(item.loan.name),
                iso(item.payment.date),
                String(format: "%.2f", item.payment.amount),
                item.payment.paymentType.label,
                escaped(item.payment.note ?? "")
            ].joined(separator: ",")
            csv += row + "\n"
        }
        return csv
    }

    /// Generates an amortization schedule CSV for a specific loan.
    static func generateAmortization(loan: Loan) -> String {
        var csv = "Month,Date,EMI,Principal,Interest,Closing Balance\n"

        let schedule = loan.amortizationSchedule()
        for row in schedule {
            let line = [
                "\(row.id + 1)",
                iso(row.date),
                String(format: "%.2f", row.emiAmount),
                String(format: "%.2f", row.principalComponent),
                String(format: "%.2f", row.interestComponent),
                String(format: "%.2f", row.closingBalance)
            ].joined(separator: ",")
            csv += line + "\n"
        }
        return csv
    }

    private static func escaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }
}

// MARK: - CSV Document

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Export Sheet

struct CSVExportSheet: View {
    let loans: [Loan]
    @Environment(\.dismiss) private var dismiss

    enum ExportType: String, CaseIterable, Identifiable {
        case summary = "Loans Summary"
        case payments = "Payment History"
        var id: String { rawValue }
    }

    @State private var exportType: ExportType = .summary
    @State private var showingExporter = false
    @State private var csvContent = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Export", selection: $exportType) {
                        ForEach(ExportType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    switch exportType {
                    case .summary:
                        Text("Exports all loans with their current status, rates, and balances.")
                    case .payments:
                        Text("Exports all payment records across all loans.")
                    }
                }

                Section {
                    Button {
                        generateAndExport()
                    } label: {
                        Label("Export as CSV", systemImage: "tablecells")
                    }
                }
            }
            .navigationTitle("Export Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: CSVDocument(text: csvContent),
                contentType: .commaSeparatedText,
                defaultFilename: filename()
            ) { result in
                if case .success = result { dismiss() }
            }
        }
    }

    private func generateAndExport() {
        switch exportType {
        case .summary:
            csvContent = CSVExporter.generateLoansSummary(loans: loans)
        case .payments:
            csvContent = CSVExporter.generatePayments(loans: loans)
        }
        showingExporter = true
    }

    private func filename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let suffix = exportType == .summary ? "loans" : "payments"
        return "loan-tracker-\(suffix)-\(f.string(from: .now))"
    }
}

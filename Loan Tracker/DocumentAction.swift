import Foundation
import SwiftData

// MARK: - Document Action

/// Maps an extraction result to a concrete SwiftData mutation.
enum DocumentAction {
    case createLoan(LoanPrefill)
    case addRateChange(loan: Loan, effectiveDate: Date, newRate: Double, note: String?)
    case updateBalance(loan: Loan, newBalance: Double, asOfDate: Date)
    case referenceOnly(documentType: LoanDocumentType)
}

// MARK: - Loan Prefill (bridges extraction → LoanFormView)

/// Carries extracted values to pre-fill LoanFormView. All fields optional
/// so partial extraction still works — the user fills in the rest.
struct LoanPrefill {
    var name: String?
    var principal: Double?
    var ratePercent: Double?
    var emi: Double?
    var tenureMonths: Int?
    var startDate: Date?
    var emiDay: Int?
    var bankName: String?
    var isFloatingRate: Bool?
    var prepaymentPenaltyPercent: Double?
    var currencyCode: String?
    var currentOutstanding: Double?
}

// MARK: - Conversion Helpers

extension LoanPrefill {
    /// Build a LoanPrefill from LLM-extracted LoanCreationFields.
    init(from fields: LoanCreationFields) {
        self.name = fields.loanName
        self.principal = fields.principalAmount > 0 ? fields.principalAmount : nil
        self.ratePercent = fields.annualInterestRatePercent > 0 ? fields.annualInterestRatePercent : nil
        self.emi = fields.monthlyEMI > 0 ? fields.monthlyEMI : nil
        self.tenureMonths = fields.tenureMonths > 0 ? fields.tenureMonths : nil
        self.emiDay = (1...31).contains(fields.emiDay) ? fields.emiDay : nil
        self.bankName = fields.bankName.isEmpty ? nil : fields.bankName
        self.isFloatingRate = fields.rateType.lowercased().contains("float") ? true :
                              fields.rateType.lowercased().contains("fixed") ? false : nil
        self.prepaymentPenaltyPercent = fields.prepaymentPenaltyPercent
        self.currencyCode = fields.currencyCode.isEmpty ? nil : fields.currencyCode

        // Parse date
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        self.startDate = formatter.date(from: fields.startDate)
    }
}

// MARK: - Action Execution

extension DocumentAction {

    /// Execute the action against the given ModelContext.
    @MainActor
    func execute(context: ModelContext) throws {
        switch self {
        case .createLoan:
            // Handled by presenting LoanFormView(prefill:) — not executed here.
            break

        case .addRateChange(let loan, let effectiveDate, let newRate, let note):
            let rc = RateChange(
                effectiveDate: effectiveDate,
                newAnnualRate: newRate,
                note: note
            )
            rc.loan = loan
            loan.rateChanges.append(rc)
            loan.annualInterestRate = newRate
            context.insert(rc)
            try context.save()

        case .updateBalance(let loan, let newBalance, _):
            loan.currentOutstanding = newBalance
            try context.save()

        case .referenceOnly:
            // No data mutation — document is for user reference only.
            break
        }
    }
}

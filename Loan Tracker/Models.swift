import Foundation
import SwiftData

// MARK: - Data Models

@Model
final class Loan {
    // All non-optional properties need defaults for CloudKit sync compatibility.
    var id: UUID = UUID()
    var name: String = ""
    var principal: Double = 0          // Original loan amount
    var annualInterestRate: Double = 0 // e.g. 0.085 means 8.5%
    var monthlyPayment: Double = 0     // EMI
    var elapsedMonths: Double = 0      // Months of EMI already paid by the bank's schedule before in-app tracking began
    var paidBeforeTracking: Double = 0 // Actual total cash paid during elapsedMonths. 0 = assume standard EMI was paid each month.
    var currentOutstanding: Double = 0 // Direct override: if > 0, this becomes the starting balance, ignoring elapsedMonths/paidBeforeTracking.
    /// The date `currentOutstanding` was actually true (e.g. the bank statement date), used as the
    /// interest-accrual anchor for `remainingBalance`. nil falls back to `createdAt` for loans saved
    /// before this field existed. Must be kept in sync whenever `currentOutstanding` is edited —
    /// otherwise interest accrues over the wrong span the next time a payment is logged.
    var currentOutstandingAsOf: Date? = nil
    var startDate: Date = Date()
    var tenureMonths: Int = 0          // Original agreed term in months
    var emiDay: Int = 1                // Day of month the EMI is auto-debited (1-31)
    /// When non-nil, this is the date of the first full EMI — overrides the
    /// default calculation of `startDate + 1 month on emiDay`. Used for loans
    /// with a Pre-EMI period (interest-only) before full EMIs begin, common
    /// in Indian home loans where disbursement and first EMI can be 1-2
    /// months apart.
    var firstEMIDate: Date? = nil
    var createdAt: Date = Date()
    /// SF Symbol key — see LoanIcon enum for valid values. Defaults to generic.
    var iconKey: String = "generic"
    /// Only one loan can be pinned at a time; pinned loans float to the top.
    var isPinned: Bool = false

    /// ISO 4217 currency code for this loan (e.g. "INR", "USD", "EUR", "GBP").
    /// Each loan carries its own currency so users with loans in multiple
    /// countries can track them side by side.
    var currencyCode: String = "USD"

    /// Whether the interest rate is floating (linked to a benchmark like
    /// repo rate, SOFR, EURIBOR) or fixed for the full tenure.
    /// Floating-rate loans should prompt the user to update when benchmarks change.
    var isFloatingRate: Bool = false

    /// Prepayment/foreclosure penalty as a percentage of the prepaid amount.
    /// 0 for floating-rate home loans in India (RBI directive, 2012).
    /// Typically 2-5% for personal/car loans, varies globally.
    var prepaymentPenaltyPercent: Double = 0

    /// Optional name of the lending bank/institution (e.g. "SBI", "Chase", "Barclays").
    /// Used for display and to associate with bank templates.
    var bankName: String = ""

    @Relationship(deleteRule: .cascade, inverse: \Payment.loan)
    var payments: [Payment] = []

    @Relationship(deleteRule: .cascade, inverse: \RateChange.loan)
    var rateChanges: [RateChange] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredDocument.loan)
    var storedDocuments: [StoredDocument]? = []

    var totalLifetimeInterest: Double {
        let totalOutflow = monthlyPayment * Double(tenureMonths)
        return totalOutflow - principal
    }

    init(name: String,
         principal: Double,
         annualInterestRate: Double,
         monthlyPayment: Double,
         elapsedMonths: Double,
         paidBeforeTracking: Double,
         currentOutstanding: Double,
         currentOutstandingAsOf: Date? = nil,
         startDate: Date,
         tenureMonths: Int,
         emiDay: Int,
         firstEMIDate: Date? = nil,
         iconKey: String = "generic",
         isPinned: Bool = false,
         currencyCode: String = Locale.current.currency?.identifier ?? "USD",
         isFloatingRate: Bool = false,
         prepaymentPenaltyPercent: Double = 0,
         bankName: String = "") {
        self.name = name
        self.principal = principal
        self.annualInterestRate = annualInterestRate
        self.monthlyPayment = monthlyPayment
        self.elapsedMonths = elapsedMonths
        self.paidBeforeTracking = paidBeforeTracking
        self.currentOutstanding = currentOutstanding
        self.currentOutstandingAsOf = currentOutstandingAsOf
        self.startDate = startDate
        self.tenureMonths = tenureMonths
        self.emiDay = emiDay
        self.firstEMIDate = firstEMIDate
        self.iconKey = iconKey
        self.isPinned = isPinned
        self.currencyCode = currencyCode
        self.isFloatingRate = isFloatingRate
        self.prepaymentPenaltyPercent = prepaymentPenaltyPercent
        self.bankName = bankName
        self.createdAt = .now
    }
}

/// Distinguishes regular EMI payments from one-time prepayments.
/// Stored as a raw String on Payment for CloudKit/SwiftData safety.
enum PaymentType: String, CaseIterable, Identifiable {
    case emi = "emi"
    case prepayment = "prepayment"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .emi: return "EMI"
        case .prepayment: return "Prepayment"
        }
    }
}

@Model
final class Payment {
    var amount: Double = 0
    var date: Date = Date()
    var note: String?
    /// "emi" or "prepayment" — see PaymentType enum.
    var type: String = PaymentType.emi.rawValue
    var loan: Loan?

    var paymentType: PaymentType {
        PaymentType(rawValue: type) ?? .emi
    }

    init(amount: Double, date: Date = .now, note: String? = nil, type: PaymentType = .emi) {
        self.amount = amount
        self.date = date
        self.note = note
        self.type = type.rawValue
    }
}

/// Tracks historical interest rate changes on floating-rate loans.
/// Each entry records when the bank revised the rate and the new value.
@Model
final class RateChange {
    var effectiveDate: Date = Date()
    var newAnnualRate: Double = 0  // e.g. 0.085 for 8.5%
    var note: String?              // e.g. "RBI repo rate cut", "Fed rate hike"
    var loan: Loan?

    init(effectiveDate: Date, newAnnualRate: Double, note: String? = nil) {
        self.effectiveDate = effectiveDate
        self.newAnnualRate = newAnnualRate
        self.note = note
    }
}

@Model
final class StoredDocument {
    var id: UUID = UUID()
    var fileName: String = ""
    var fileType: String = ""        // "pdf", "image"
    var addedDate: Date = Date()
    var documentType: String = ""    // LoanDocumentType raw value
    var note: String?

    /// Relative path within the app's documents directory.
    /// Actual file stored at: Documents/LoanDocuments/{id}.{ext}
    var relativePath: String = ""

    var loan: Loan?

    init(fileName: String, fileType: String, documentType: String, note: String? = nil) {
        self.fileName = fileName
        self.fileType = fileType
        self.documentType = documentType
        self.note = note
        let ext = fileType == "pdf" ? "pdf" : "jpg"
        self.relativePath = "\(id.uuidString).\(ext)"
    }

    /// Full URL to the stored file.
    var fileURL: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent("LoanDocuments").appendingPathComponent(relativePath)
    }
}

// MARK: - Prepayment Projection

struct PrepaymentProjection {
    let monthsRemaining: Double     // can be fractional
    let interestRemaining: Double
    let totalCashRemaining: Double
    let closeDate: Date
    let isPaidOff: Bool
}

/// A single row in the amortization schedule.
struct AmortizationRow: Identifiable {
    let id: Int            // month index (0-based from today)
    let date: Date
    let emiAmount: Double
    let principalComponent: Double
    let interestComponent: Double
    let closingBalance: Double
}

/// Strategy choice after making a prepayment.
enum PrepaymentStrategy: String, CaseIterable, Identifiable {
    case reduceTenure = "Reduce Tenure"
    case reduceEMI = "Reduce EMI"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .reduceTenure: return "Keep EMI same, close loan sooner"
        case .reduceEMI: return "Keep tenure same, lower monthly payment"
        }
    }
}

// MARK: - Currency Helpers

/// Common currencies with display metadata. Used by the loan form picker.
enum SupportedCurrency: String, CaseIterable, Identifiable {
    case inr = "INR"
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case aed = "AED"
    case sgd = "SGD"
    case aud = "AUD"
    case cad = "CAD"
    case jpy = "JPY"
    case myr = "MYR"
    case thb = "THB"
    case chf = "CHF"
    case zar = "ZAR"
    case brl = "BRL"
    case mxn = "MXN"
    case ngn = "NGN"
    case kes = "KES"
    case php = "PHP"
    case idr = "IDR"
    case vnd = "VND"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inr: return "₹ Indian Rupee"
        case .usd: return "$ US Dollar"
        case .eur: return "€ Euro"
        case .gbp: return "£ British Pound"
        case .aed: return "د.إ UAE Dirham"
        case .sgd: return "S$ Singapore Dollar"
        case .aud: return "A$ Australian Dollar"
        case .cad: return "C$ Canadian Dollar"
        case .jpy: return "¥ Japanese Yen"
        case .myr: return "RM Malaysian Ringgit"
        case .thb: return "฿ Thai Baht"
        case .chf: return "CHF Swiss Franc"
        case .zar: return "R South African Rand"
        case .brl: return "R$ Brazilian Real"
        case .mxn: return "$ Mexican Peso"
        case .ngn: return "₦ Nigerian Naira"
        case .kes: return "KSh Kenyan Shilling"
        case .php: return "₱ Philippine Peso"
        case .idr: return "Rp Indonesian Rupiah"
        case .vnd: return "₫ Vietnamese Dong"
        }
    }

    var symbol: String {
        switch self {
        case .inr: return "₹"
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .aed: return "د.إ"
        case .sgd: return "S$"
        case .aud: return "A$"
        case .cad: return "C$"
        case .jpy: return "¥"
        case .myr: return "RM"
        case .thb: return "฿"
        case .chf: return "CHF"
        case .zar: return "R"
        case .brl: return "R$"
        case .mxn: return "$"
        case .ngn: return "₦"
        case .kes: return "KSh"
        case .php: return "₱"
        case .idr: return "Rp"
        case .vnd: return "₫"
        }
    }
}

// MARK: - Amortization Math

extension Loan {
    var monthlyRate: Double { annualInterestRate / 12.0 }

    /// Number of EMIs paid by today, auto-derived from startDate + emiDay.
    /// Assumes the first EMI lands one calendar month after startDate on the EMI day.
    /// Clamps the EMI day to the month's last day for short months (e.g., 31 → 28 in Feb).
    /// The actual anchor date for all EMI scheduling. Returns the explicit
    /// `firstEMIDate` when the user has set one (Pre-EMI loans), otherwise
    /// the conventional default of `startDate + 1 month on emiDay`.
    var effectiveFirstEMIDate: Date {
        if let override = firstEMIDate { return override }
        let cal = Calendar.current
        guard let oneMonthAfter = cal.date(byAdding: .month, value: 1, to: startDate) else { return startDate }
        var comps = cal.dateComponents([.year, .month], from: oneMonthAfter)
        guard let firstOfMonth = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth) else { return oneMonthAfter }
        comps.day = min(emiDay, range.upperBound - 1)
        return cal.date(from: comps) ?? oneMonthAfter
    }

    /// Translates any date onto the loan's EMI-cycle timeline: how many EMI
    /// cycles (first EMI + emiDay cadence, no gaps assumed) have occurred by
    /// that date. Used both for the live "as of today" baseline and to place
    /// a specific logged payment's date on the same timeline, so it can be
    /// reconciled against the baseline without double-counting.
    private func emiCyclesElapsed(asOf referenceDate: Date) -> Int {
        let cal = Calendar.current

        func emiDateIn(year: Int, month: Int) -> Date? {
            var dc = DateComponents(year: year, month: month, day: 1)
            guard let firstOfMonth = cal.date(from: dc),
                  let range = cal.range(of: .day, in: .month, for: firstOfMonth) else { return nil }
            let lastDay = range.upperBound - 1
            dc.day = min(emiDay, lastDay)
            return cal.date(from: dc)
        }

        // First EMI anchor — uses `firstEMIDate` if set (Pre-EMI loans), else default.
        let firstEMI = effectiveFirstEMIDate
        let firstComps = cal.dateComponents([.year, .month], from: firstEMI)
        guard let firstYear = firstComps.year, let firstMonth = firstComps.month else { return 0 }

        if referenceDate < firstEMI { return 0 }

        // Count months from firstEMI's month to the reference date's month.
        let refComps = cal.dateComponents([.year, .month, .day], from: referenceDate)
        guard let refYear = refComps.year,
              let refMonth = refComps.month,
              let refDay = refComps.day else { return 0 }

        let monthDiff = (refYear * 12 + refMonth) - (firstYear * 12 + firstMonth)

        // Has the reference month's EMI day been reached?
        guard let refMonthEMI = emiDateIn(year: refYear, month: refMonth) else {
            return max(0, monthDiff)
        }
        let refMonthEMIDay = cal.component(.day, from: refMonthEMI)

        return refDay >= refMonthEMIDay ? monthDiff + 1 : monthDiff
    }

    /// Number of EMIs paid by today, auto-derived from startDate + emiDay.
    /// Assumes standard EMI cadence with no gaps — used as the live baseline
    /// for `remainingBalance` when no `currentOutstanding` override is set.
    var derivedElapsedMonths: Int {
        emiCyclesElapsed(asOf: Date())
    }

    /// Single reconciled count of completed EMI cycles — the one source of
    /// truth behind both `nextEMIDate` and `totalMonthsPaid`.
    ///
    /// Baseline is `elapsedMonths` (override mode: the count implied by
    /// `currentOutstanding`) — the number the loan form lets you edit
    /// directly under "EMIs Paid". Each logged EMI-type payment is placed on
    /// the EMI-cycle timeline by its own date, and only advances the total if
    /// it implies a *later* cycle than the baseline already covers — so
    /// logging a payment for a month the baseline already accounts for
    /// doesn't add on top of it. (Summing `elapsedMonths + payments.count`
    /// unconditionally was the cause of double-counted "months paid".)
    var totalEMIsCompleted: Int {
        let baseline = currentOutstanding > 0
            ? Int(impliedMonthsPaid.rounded())
            : Int(elapsedMonths)

        let latestLoggedCycle = payments
            .filter { $0.paymentType == .emi }
            .map { emiCyclesElapsed(asOf: $0.date) }
            .max() ?? 0

        return max(baseline, latestLoggedCycle)
    }

    var totalPaid: Double {
        payments.reduce(0) { $0 + $1.amount }
    }

    /// Current outstanding balance. Resolution order:
    /// 1. If `currentOutstanding` is set, use that as the starting balance
    ///    (as of `currentOutstandingAsOf`, falling back to `createdAt`).
    /// 2. Otherwise compute from principal + elapsed amortization (using effective EMI
    ///    if `paidBeforeTracking` is set).
    /// 3. Then apply tracked payments, compounding interest between them.
    var remainingBalance: Double {
        let r = monthlyRate
        var balance: Double
        var cursor: Date
        // Cycles already absorbed into the baseline below (non-override mode only).
        // EMI-type payments dated within this many cycles are skipped further down
        // so they aren't subtracted a second time on top of the baseline.
        var elapsedBaseline = 0

        if currentOutstanding > 0 {
            // Override mode: bank statement is the source of truth, as of
            // `currentOutstandingAsOf` (the statement date) — falling back to
            // `createdAt` only for loans saved before that field existed.
            balance = currentOutstanding
            cursor = Calendar.current.startOfDay(for: currentOutstandingAsOf ?? createdAt)
        } else {
            // Compute via amortization from start date, using the same reconciled
            // EMI-cycle count as `nextEMIDate`/`totalMonthsPaid` (`totalEMIsCompleted`)
            // rather than the raw live calendar count — so a logged EMI payment that's
            // already reflected in that count isn't subtracted again below.
            let elapsed = max(0, min(Double(totalEMIsCompleted),
                                     Double(tenureMonths == 0 ? Int.max : tenureMonths)))
            elapsedBaseline = Int(elapsed.rounded())
            let M_elapsed: Double = (paidBeforeTracking > 0 && elapsed > 0)
                ? paidBeforeTracking / elapsed
                : monthlyPayment

            if r == 0 {
                balance = principal - elapsed * M_elapsed
            } else {
                balance = principal * pow(1 + r, elapsed) - M_elapsed * (pow(1 + r, elapsed) - 1) / r
            }
            balance = max(0, balance)

            let elapsedInt = Int(elapsed.rounded())
            let rawCursor = Calendar.current.date(byAdding: .month, value: elapsedInt, to: startDate) ?? startDate
            cursor = Calendar.current.startOfDay(for: rawCursor)
        }

        // Build a merged timeline of payments and rate changes, then walk forward
        // accruing interest at the applicable rate between each event.
        struct TimelineEvent: Comparable {
            let date: Date
            let payment: Double       // 0 if this is a rate-change-only event
            let newMonthlyRate: Double? // non-nil if this event changes the rate
            static func < (lhs: TimelineEvent, rhs: TimelineEvent) -> Bool { lhs.date < rhs.date }
        }

        // EMI-type payments already covered by `elapsedBaseline` are excluded here —
        // otherwise they'd double-count against the baseline above. Prepayments are
        // always additive on top of the standard EMI regardless of date, so they're
        // never skipped.
        // Normalized to midnight so month-gap math (`monthsBetween`) always sees clean
        // calendar-day boundaries, regardless of leftover time-of-day on stored dates.
        var events: [TimelineEvent] = payments.compactMap { payment in
            if payment.paymentType == .emi, emiCyclesElapsed(asOf: payment.date) <= elapsedBaseline {
                return nil
            }
            return TimelineEvent(date: Calendar.current.startOfDay(for: payment.date), payment: payment.amount, newMonthlyRate: nil)
        }
        for rc in rateChanges {
            events.append(TimelineEvent(date: Calendar.current.startOfDay(for: rc.effectiveDate), payment: 0, newMonthlyRate: rc.newAnnualRate / 12.0))
        }
        events.sort()

        var currentRate = r
        for event in events {
            let monthsDelta = max(0, Self.monthsBetween(cursor, event.date))
            balance = balance * pow(1 + currentRate, monthsDelta)
            if let newRate = event.newMonthlyRate {
                currentRate = newRate
            }
            balance -= event.payment
            cursor = max(cursor, event.date)
        }

        return max(0, balance)
    }

    /// Principal actually paid down so far = original − current outstanding.
    /// This is always accurate because it derives from `remainingBalance`.
    var totalPrincipalPaid: Double {
        return max(0, principal - remainingBalance)
    }

    /// Total cash that has actually left your account toward this loan.
    /// In override mode we don't know historical payments directly, so we *estimate*
    /// by solving the amortization equation: how many scheduled EMIs would reduce
    /// principal to currentOutstanding?
    var totalCashOutflow: Double {
        if currentOutstanding > 0 {
            return impliedCashPaidBeforeOverride + totalPaid
        }
        let elapsed = Double(derivedElapsedMonths)
        let elapsedCash = paidBeforeTracking > 0
            ? paidBeforeTracking
            : monthlyPayment * elapsed
        return elapsedCash + totalPaid
    }

    /// Implied number of EMIs paid to reach currentOutstanding, when override mode is active.
    /// Solves the amortization equation B_k = P·(1+r)^k − M·((1+r)^k − 1)/r for k.
    /// Returns 0 outside of override mode or when the math doesn't resolve cleanly.
    var impliedMonthsPaid: Double {
        guard currentOutstanding > 0, currentOutstanding < principal else { return 0 }
        let r = monthlyRate
        let M = monthlyPayment
        let P = principal
        let B = currentOutstanding

        if r == 0 {
            return (P - B) / max(M, 0.01)
        }

        let MoverR = M / r
        let numerator = B - MoverR
        let denominator = P - MoverR
        guard abs(denominator) > 0.001 else { return 0 }
        let ratio = numerator / denominator
        guard ratio > 0 else { return 0 }

        let k = log(ratio) / log(1 + r)
        return max(0, k)
    }

    /// "If you'd paid exactly the scheduled EMI, how much cash would it take to reach
    /// `currentOutstanding`?" — used only when override mode is active.
    private var impliedCashPaidBeforeOverride: Double {
        guard currentOutstanding > 0, currentOutstanding < principal else { return 0 }
        if monthlyRate == 0 {
            return principal - currentOutstanding
        }
        return monthlyPayment * impliedMonthsPaid
    }

    /// Interest you've actually paid = total cash out − principal paid down.
    var totalInterestPaid: Double {
        return max(0, totalCashOutflow - totalPrincipalPaid)
    }

    /// True when the interest-paid figure includes an estimated component
    /// (i.e., the user used the currentOutstanding override and we had to infer history).
    var isInterestPaidEstimated: Bool {
        return currentOutstanding > 0
    }

    /// Months remaining until loan is closed at current EMI. Nil if EMI doesn't cover interest.
    var estimatedMonthsRemaining: Int? {
        let P = remainingBalance
        let r = monthlyRate
        let M = monthlyPayment

        guard P > 0 else { return 0 }
        guard M > 0 else { return nil }
        if r == 0 { return Int(ceil(P / M)) }
        guard M > P * r else { return nil }

        let n = -log(1 - (P * r) / M) / log(1 + r)
        // Snap to the integer below when n is within FP-noise tolerance of it.
        // For a loan exactly on schedule the formula produces something like
        // 28.9999999 or 29.0000001 — naive ceil would add a spurious month
        // and drift estimatedCloseDate one month past scheduledEndDate.
        let floored = floor(n)
        let fractional = n - floored
        if fractional < 0.01 && floored >= 1 {
            return Int(floored)
        }
        return Int(ceil(n))
    }

    var estimatedCloseDate: Date? {
        guard let months = estimatedMonthsRemaining else { return nil }
        // Already paid off — close date is today.
        guard months > 0 else { return Date() }
        // Anchor on the EMI cadence, not on .now. The last EMI happens at
        // nextEMIDate + (N-1) months — not today + N months, which would drift
        // by the gap between today and the next EMI date and end up off by
        // up to a month vs scheduledEndDate.
        guard let next = nextEMIDate else { return nil }
        return Calendar.current.date(byAdding: .month, value: months - 1, to: next)
    }

    /// Project forward from current remaining balance with optional prepayment.
    /// - `extraLumpSum`: one-time amount paid today, reduces principal immediately.
    /// - `extraMonthly`: amount added to every future EMI from now until closure.
    /// Returns nil if (EMI + extra) doesn't cover monthly interest — loan would never close.
    func projection(extraLumpSum: Double = 0, extraMonthly: Double = 0) -> PrepaymentProjection? {
        let actualLump = max(0, min(extraLumpSum, remainingBalance))
        let P = remainingBalance - actualLump
        let M = monthlyPayment + max(0, extraMonthly)
        let r = monthlyRate

        // Paid off entirely with lump sum
        if P <= 0.01 {
            return PrepaymentProjection(
                monthsRemaining: 0,
                interestRemaining: max(0, actualLump - remainingBalance),
                totalCashRemaining: actualLump,
                closeDate: .now,
                isPaidOff: true
            )
        }

        guard M > 0 else { return nil }

        let months: Double
        if r == 0 {
            months = P / M
        } else {
            guard M > P * r else { return nil }  // doesn't cover interest
            months = -log(1 - (P * r) / M) / log(1 + r)
        }

        let totalCash = actualLump + M * months
        let interest = max(0, totalCash - remainingBalance)
        let close = Calendar.current.date(byAdding: .month, value: Int(ceil(months)), to: .now) ?? .now

        return PrepaymentProjection(
            monthsRemaining: months,
            interestRemaining: interest,
            totalCashRemaining: totalCash,
            closeDate: close,
            isPaidOff: false
        )
    }

    /// Returns the outstanding balance month-by-month from today until the loan is paid off.
    /// Index 0 = balance now (after any lump-sum), index N = balance after N more EMIs.
    /// Used by the playground chart to visualize how prepayment changes the trajectory.
    /// Caps at maxMonths so a degenerate loan doesn't loop forever.
    func balanceTrajectory(extraLumpSum: Double = 0,
                           extraMonthly: Double = 0,
                           maxMonths: Int = 600) -> [Double] {
        var balance = max(0, remainingBalance - max(0, extraLumpSum))
        let M = monthlyPayment + max(0, extraMonthly)
        let r = monthlyRate

        var points: [Double] = [balance]

        // Sanity guards: positive EMI and EMI exceeds monthly interest (else infinite loan)
        guard M > 0 else { return points }

        var month = 0
        while balance > 0.01 && month < maxMonths {
            let interest = balance * r
            let principal = M - interest
            if principal <= 0 { break }  // EMI doesn't cover interest — bail rather than spin
            balance = max(0, balance - principal)
            points.append(balance)
            month += 1
        }
        return points
    }

    // MARK: - Amortization Schedule

    /// Month-by-month amortization schedule from the current balance forward.
    /// Each row shows how the EMI splits into principal and interest components.
    func amortizationSchedule(extraMonthly: Double = 0,
                              extraLumpSum: Double = 0,
                              maxMonths: Int = 600) -> [AmortizationRow] {
        var balance = max(0, remainingBalance - max(0, extraLumpSum))
        let M = monthlyPayment + max(0, extraMonthly)
        let r = monthlyRate
        let cal = Calendar.current
        let anchor = nextEMIDate ?? Date()
        var rows: [AmortizationRow] = []

        guard M > 0 else { return rows }

        var month = 0
        while balance > 0.01 && month < maxMonths {
            let interest = balance * r
            let principalPortion = min(M - interest, balance)
            if principalPortion <= 0 { break }
            balance = max(0, balance - principalPortion)
            let date = cal.date(byAdding: .month, value: month, to: anchor) ?? anchor
            rows.append(AmortizationRow(
                id: month,
                date: date,
                emiAmount: interest + principalPortion,
                principalComponent: principalPortion,
                interestComponent: interest,
                closingBalance: balance
            ))
            month += 1
        }
        return rows
    }

    // MARK: - Prepayment Strategies

    /// After a prepayment, banks offer two choices:
    /// 1. Reduce tenure (keep same EMI) — the default in the existing playground
    /// 2. Reduce EMI (keep same tenure) — useful for improving monthly cash flow
    ///
    /// This returns the new EMI if the user keeps the remaining tenure fixed.
    func reducedEMI(afterPrepayment lumpSum: Double) -> Double? {
        let newBalance = max(0, remainingBalance - max(0, lumpSum))
        guard let months = estimatedMonthsRemaining, months > 0 else { return nil }
        let r = monthlyRate
        if r == 0 { return newBalance / Double(months) }
        let factor = pow(1 + r, Double(months))
        guard factor > 1 else { return nil }
        return newBalance * r * factor / (factor - 1)
    }

    /// Net effective prepayment after deducting penalty charges.
    /// penalty = lumpSum × prepaymentPenaltyPercent / 100
    func effectivePrepayment(_ lumpSum: Double) -> Double {
        let penalty = lumpSum * prepaymentPenaltyPercent / 100.0
        return max(0, lumpSum - penalty)
    }

    /// Originally agreed end date based on tenure.
    var scheduledEndDate: Date? {
        guard tenureMonths > 0 else { return nil }
        // Tenure is counted from the first full EMI, so end = firstEMI + tenure - 1 month
        // (the Nth EMI is the last one, not an N+1 anchor).
        let firstEMI = effectiveFirstEMIDate
        return Calendar.current.date(byAdding: .month, value: tenureMonths - 1, to: firstEMI)
    }

    var nextEMIDate: Date? {
        guard emiDay >= 1, emiDay <= 31 else { return nil }

        let cal = Calendar.current

        // First EMI anchor — uses `firstEMIDate` if set (Pre-EMI loans), else default.
        let firstEMI = effectiveFirstEMIDate
        let firstComps = cal.dateComponents([.year, .month], from: firstEMI)
        guard let firstYear = firstComps.year, let firstMonth = firstComps.month else { return nil }

        /// Returns the date of the N-th EMI (0 = first EMI).
        /// Handles month/year overflow when N is large.
        func nthEMIDate(_ n: Int) -> Date? {
            // Convert "first month + n" into a real (year, month) pair
            let totalMonthsFromYearZero = (firstYear * 12) + (firstMonth - 1) + n
            let year  = totalMonthsFromYearZero / 12
            let month = (totalMonthsFromYearZero % 12) + 1

            var dc = DateComponents(year: year, month: month, day: 1)
            guard let firstOfMonth = cal.date(from: dc),
                  let range = cal.range(of: .day, in: .month, for: firstOfMonth) else { return nil }
            dc.day = min(emiDay, range.upperBound - 1)
            return cal.date(from: dc)
        }

        let totalEMIsPaid = totalEMIsCompleted

        // If the loan is fully paid up per its schedule, there's no next EMI.
        if tenureMonths > 0 && totalEMIsPaid >= tenureMonths { return nil }

        // The next EMI is the one immediately following the last paid one,
        // i.e., at zero-based index = totalEMIsPaid (0 → first EMI, 1 → second, …).
        return nthEMIDate(totalEMIsPaid)
    }

    var daysUntilNextEMI: Int? {
        guard let next = nextEMIDate else { return nil }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: .now)
        return cal.dateComponents([.day], from: startOfToday, to: next).day
    }

    var emiDayDisplay: String {
        let suffix: String
        switch emiDay {
        case 11, 12, 13: suffix = "th"
        default:
            switch emiDay % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(emiDay)\(suffix)"
    }

    var tenureDisplay: String {
        guard tenureMonths > 0 else { return "—" }
        let years = tenureMonths / 12
        let months = tenureMonths % 12
        switch (years, months) {
        case (0, let m): return "\(m) month\(m == 1 ? "" : "s")"
        case (let y, 0): return "\(y) year\(y == 1 ? "" : "s")"
        case (let y, let m): return "\(y)y \(m)m"
        }
    }

    /// Only count EMI-type payments toward "months paid".
    /// Lump-sum prepayments reduce principal but don't represent an EMI cycle.
    var totalMonthsPaid: Int {
        totalEMIsCompleted
    }

    /// How many EMIs *should* have been paid by today, based on the loan's
    /// effective first EMI date (respects Pre-EMI override). Used to detect
    /// missed payments.
    var expectedMonthsPaidByNow: Int {
        let cal = Calendar.current
        let firstEMI = effectiveFirstEMIDate
        let now = Date()
        guard now >= firstEMI else { return 0 }
        // Count completed EMI cycles between firstEMI and now.
        let months = cal.dateComponents([.month], from: firstEMI, to: now).month ?? 0
        let expected = months + 1   // +1 because firstEMI itself counts as month 1
        let capped = min(expected, tenureMonths > 0 ? tenureMonths : expected)
        return max(0, capped)
    }

    /// Number of EMIs missed (expected - actual). nil if loan is up-to-date or ahead.
    var missedEMIs: Int? {
        let expected = expectedMonthsPaidByNow
        let actual = totalMonthsPaid
        return expected > actual ? (expected - actual) : nil
    }

    var scheduleStatus: String? {
        guard let estimated = estimatedCloseDate,
              let scheduled = scheduledEndDate,
              (elapsedMonths > 0 || !payments.isEmpty) else { return nil }
        let diffMonths = Calendar.current.dateComponents([.month], from: estimated, to: scheduled).month ?? 0
        if diffMonths == 0 { return "on schedule" }

        let abs = Swift.abs(diffMonths)
        let direction = diffMonths > 0 ? "ahead" : "behind"

        // For large gaps, use years + months instead of "159 months ahead",
        // which is hard to grasp and tends to wrap in tight UI rows.
        let label: String
        if abs >= 24 {
            let years = abs / 12
            let months = abs % 12
            label = months == 0 ? "\(years)y" : "\(years)y \(months)mo"
        } else {
            label = "\(abs) mo"
        }
        return "\(label) \(direction)"
    }

    var progressFraction: Double {
        guard principal > 0 else { return 0 }
        return min(1.0, max(0.0, 1.0 - remainingBalance / principal))
    }

    /// Whole calendar months between two dates, plus a fractional remainder for
    /// any leftover days — proportioned against the actual length of the month
    /// the remainder falls in (not a fixed average). This matches how EMI
    /// interest is charged: a clean calendar month always yields exactly 1.0,
    /// regardless of whether that specific month has 28, 30, or 31 days.
    private static func monthsBetween(_ from: Date, _ to: Date) -> Double {
        let cal = Calendar.current
        let comps = cal.dateComponents([.month, .day], from: from, to: to)
        let wholeMonths = comps.month ?? 0
        let remainderDays = comps.day ?? 0
        guard let monthAnchor = cal.date(byAdding: .month, value: wholeMonths, to: from) else {
            return Double(wholeMonths)
        }
        let daysInThatMonth = cal.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        return Double(wholeMonths) + Double(remainderDays) / Double(daysInThatMonth)
    }
}

// MARK: - Loan Icons

/// SF Symbol options shown in the picker when creating/editing a loan.
/// Stored as a string key on `Loan.iconKey` for SwiftData/CloudKit safety.
enum LoanIcon: String, CaseIterable, Identifiable {
    case generic = "generic"
    case home    = "home"
    case car     = "car"
    case bike    = "bike"
    case person  = "person"
    case business = "business"
    case education = "education"
    case medical = "medical"
    case gold    = "gold"
    case card    = "card"

    var id: String { rawValue }

    /// SF Symbol name used by SwiftUI's Image(systemName:).
    var systemImage: String {
        switch self {
        case .generic:   return "banknote.fill"
        case .home:      return "house.fill"
        case .car:       return "car.fill"
        case .bike:      return "bicycle"
        case .person:    return "person.crop.circle.fill"
        case .business:  return "briefcase.fill"
        case .education: return "graduationcap.fill"
        case .medical:   return "cross.case.fill"
        case .gold:      return "circle.hexagongrid.fill"
        case .card:      return "creditcard.fill"
        }
    }

    /// Display label in the picker.
    var label: String {
        switch self {
        case .generic:   return "Generic"
        case .home:      return "Home"
        case .car:       return "Car"
        case .bike:      return "Bike"
        case .person:    return "Personal"
        case .business:  return "Business"
        case .education: return "Education"
        case .medical:   return "Medical"
        case .gold:      return "Gold"
        case .card:      return "Credit Card"
        }
    }

    /// Look up an icon from a stored key, falling back to generic.
    static func resolve(_ key: String?) -> LoanIcon {
        guard let key = key, let icon = LoanIcon(rawValue: key) else { return .generic }
        return icon
    }
}

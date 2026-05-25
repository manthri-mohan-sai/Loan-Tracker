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

    @Relationship(deleteRule: .cascade, inverse: \Payment.loan)
    var payments: [Payment] = []

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
         startDate: Date,
         tenureMonths: Int,
         emiDay: Int,
         firstEMIDate: Date? = nil,
         iconKey: String = "generic",
         isPinned: Bool = false) {
        self.name = name
        self.principal = principal
        self.annualInterestRate = annualInterestRate
        self.monthlyPayment = monthlyPayment
        self.elapsedMonths = elapsedMonths
        self.paidBeforeTracking = paidBeforeTracking
        self.currentOutstanding = currentOutstanding
        self.startDate = startDate
        self.tenureMonths = tenureMonths
        self.emiDay = emiDay
        self.firstEMIDate = firstEMIDate
        self.iconKey = iconKey
        self.isPinned = isPinned
        self.createdAt = .now
    }
}

@Model
final class Payment {
    var amount: Double = 0
    var date: Date = Date()
    var note: String?
    var loan: Loan?

    init(amount: Double, date: Date = .now, note: String? = nil) {
        self.amount = amount
        self.date = date
        self.note = note
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

    var derivedElapsedMonths: Int {
        let cal = Calendar.current
        let today = Date()

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

        if today < firstEMI { return 0 }

        // Count months from firstEMI's month to today's month.
        let todayComps = cal.dateComponents([.year, .month, .day], from: today)
        guard let todayYear = todayComps.year,
              let todayMonth = todayComps.month,
              let todayDay = todayComps.day else { return 0 }

        let monthDiff = (todayYear * 12 + todayMonth) - (firstYear * 12 + firstMonth)

        // Has today's month's EMI day been reached?
        guard let todayMonthEMI = emiDateIn(year: todayYear, month: todayMonth) else {
            return max(0, monthDiff)
        }
        let todayMonthEMIDay = cal.component(.day, from: todayMonthEMI)

        return todayDay >= todayMonthEMIDay ? monthDiff + 1 : monthDiff
    }

    var totalPaid: Double {
        payments.reduce(0) { $0 + $1.amount }
    }

    /// Current outstanding balance. Resolution order:
    /// 1. If `currentOutstanding` is set, use that as the starting balance (as of `createdAt`).
    /// 2. Otherwise compute from principal + elapsed amortization (using effective EMI
    ///    if `paidBeforeTracking` is set).
    /// 3. Then apply tracked payments, compounding interest between them.
    var remainingBalance: Double {
        let r = monthlyRate
        var balance: Double
        var cursor: Date

        if currentOutstanding > 0 {
            // Override mode: bank statement is the source of truth, as of loan creation.
            balance = currentOutstanding
            cursor = createdAt
        } else {
            // Compute via amortization from start date, using auto-derived elapsed count.
            let elapsed = max(0, min(Double(derivedElapsedMonths),
                                     Double(tenureMonths == 0 ? Int.max : tenureMonths)))
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
            cursor = Calendar.current.date(byAdding: .month, value: elapsedInt, to: startDate) ?? startDate
        }

        // Apply tracked payments on top of either starting point, accruing interest between them.
        let sorted = payments.sorted { $0.date < $1.date }
        for p in sorted {
            let monthsDelta = max(0, Self.monthsBetween(cursor, p.date))
            balance = balance * pow(1 + r, monthsDelta) - p.amount
            cursor = max(cursor, p.date)
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

        // Count tracked payments that count as a full EMI (>= half the EMI amount).
        let trackedFullPayments = payments.filter { $0.amount >= monthlyPayment * 0.5 }.count

        // Base count of EMIs paid before tracking. Mirrors `totalMonthsPaid`:
        // when the user provided `currentOutstanding`, we solve the amortization
        // for the implied month count. Otherwise we use `elapsedMonths` (which
        // the form auto-detects from startDate but the user can override).
        let baseMonths: Int = currentOutstanding > 0
            ? Int(impliedMonthsPaid.rounded())
            : Int(elapsedMonths)
        let totalEMIsPaid = baseMonths + trackedFullPayments

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

    var totalMonthsPaid: Int {
        let baseMonths: Double = currentOutstanding > 0
            ? impliedMonthsPaid
            : Double(derivedElapsedMonths)
        return Int(baseMonths.rounded()) + payments.count
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

    private static func monthsBetween(_ from: Date, _ to: Date) -> Double {
        let seconds = to.timeIntervalSince(from)
        let secondsPerMonth = (365.25 / 12.0) * 24 * 60 * 60
        return seconds / secondsPerMonth
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
        case .generic:   return "indianrupeesign.circle.fill"
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

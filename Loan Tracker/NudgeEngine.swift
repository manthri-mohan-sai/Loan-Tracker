import Foundation
import SwiftUI

// MARK: - Types

enum NudgeKind: String, CaseIterable, Codable {
    case prepaymentImpact   // "Pay ₹X extra/mo → save ₹Y in interest"
    case lumpSumImpact      // "₹X one-time → save ₹Y in interest"
    case aheadOfSchedule    // "You're N months ahead on X"
    case loanClosingSoon    // "X closes in N months — you'll free up ₹Y/mo"
    case milestone          // "You've crossed 50% on X"
}

struct Nudge: Identifiable, Hashable {
    let id: String          // composite for dedup + dismissal tracking
    let kind: NudgeKind
    let title: String       // short header (e.g. "Save Interest")
    let icon: String        // SF Symbol name for the leading icon
    let tint: NudgeTint     // accent color category
    let message: String     // main body — the actual nudge
    let actionLabel: String?// if non-nil, show a CTA button
    let loanID: UUID?       // drill-down target on tap
    let score: Int          // higher = more impactful; used to pick "best" nudge
}

/// Color category for the nudge — keeps things visually consistent.
enum NudgeTint {
    case savings   // green-ish, money saved
    case progress  // accent, encouragement
    case milestone // orange, celebratory
    case neutral   // secondary, informational

    var color: Color {
        switch self {
        case .savings:   return .green
        case .progress:  return .accentColor
        case .milestone: return .orange
        case .neutral:   return .secondary
        }
    }
}

// MARK: - Engine

enum NudgeEngine {

    /// Compute all candidate nudges, sorted by score (highest impact first).
    static func compute(loans: [Loan]) -> [Nudge] {
        var candidates: [Nudge] = []
        let active = loans.filter { $0.remainingBalance > 0.01 }
        guard !active.isEmpty else { return [] }

        candidates.append(contentsOf: prepaymentImpactNudges(active))
        candidates.append(contentsOf: lumpSumImpactNudges(active))
        candidates.append(contentsOf: aheadOfScheduleNudges(active))
        candidates.append(contentsOf: loanClosingSoonNudges(active))
        candidates.append(contentsOf: milestoneNudges(active))

        return candidates.sorted { $0.score > $1.score }
    }

    /// Best nudge to show right now: highest-score that hasn't been dismissed recently.
    static func topNudge(for loans: [Loan]) -> Nudge? {
        compute(loans: loans).first { !isDismissed($0) }
    }

    // MARK: - Individual generators

    /// Pay extra/mo on the loan with the highest interest-rate leverage
    /// (remaining balance × annual rate). That's the loan where extra payments
    /// save the most interest.
    private static func prepaymentImpactNudges(_ loans: [Loan]) -> [Nudge] {
        guard let target = loans.max(by: {
            $0.remainingBalance * $0.annualInterestRate < $1.remainingBalance * $1.annualInterestRate
        }) else { return [] }

        // Suggest ~15% of EMI as extra, rounded to a sensible increment.
        let roundUnit = roundingUnit(for: target.currencyCode, emi: target.monthlyPayment)
        let suggestedExtra = max(roundUnit, ((target.monthlyPayment * 0.15) / roundUnit).rounded() * roundUnit)

        guard let baseline = target.projection(extraLumpSum: 0, extraMonthly: 0),
              let scenario = target.projection(extraLumpSum: 0, extraMonthly: suggestedExtra) else {
            return []
        }

        let interestSaved = baseline.interestRemaining - scenario.interestRemaining
        let monthsSaved = Int(ceil(baseline.monthsRemaining - scenario.monthsRemaining))

        // Only show if it actually saves something meaningful.
        guard interestSaved > roundUnit * 2, monthsSaved >= 1 else { return [] }

        let cc = target.currencyCode
        return [Nudge(
            id: "\(NudgeKind.prepaymentImpact.rawValue)-\(target.id.uuidString)",
            kind: .prepaymentImpact,
            title: "Save Interest",
            icon: "arrow.up.right.circle.fill",
            tint: .savings,
            message: "Paying \(currencyCompact(suggestedExtra, code: cc)) extra/mo on \(target.name) closes it \(monthsSaved) month\(monthsSaved == 1 ? "" : "s") sooner and saves \(currencyCompact(interestSaved, code: cc)) in interest.",
            actionLabel: "Try in Playground",
            loanID: target.id,
            score: scoreFromSavings(interestSaved)
        )]
    }

    /// A one-time lump sum prepayment on the highest-interest loan.
    private static func lumpSumImpactNudges(_ loans: [Loan]) -> [Nudge] {
        guard let target = loans.max(by: { $0.annualInterestRate < $1.annualInterestRate }) else { return [] }

        // ~10% of remaining balance, rounded to a sensible unit.
        let raw = target.remainingBalance * 0.10
        let lumpUnit = roundingUnit(for: target.currencyCode, emi: target.monthlyPayment) * 20
        let suggestedLump = max(lumpUnit, (raw / lumpUnit).rounded() * lumpUnit)
        guard suggestedLump < target.remainingBalance * 0.5 else { return [] }

        guard let baseline = target.projection(extraLumpSum: 0, extraMonthly: 0),
              let scenario = target.projection(extraLumpSum: suggestedLump, extraMonthly: 0) else {
            return []
        }

        let interestSaved = baseline.interestRemaining - scenario.interestRemaining
        let monthsSaved = Int(ceil(baseline.monthsRemaining - scenario.monthsRemaining))

        guard interestSaved > lumpUnit else { return [] }

        let cc = target.currencyCode
        return [Nudge(
            id: "\(NudgeKind.lumpSumImpact.rawValue)-\(target.id.uuidString)",
            kind: .lumpSumImpact,
            title: "Lump Sum Opportunity",
            icon: "bolt.circle.fill",
            tint: .savings,
            message: "A one-time \(currencyCompact(suggestedLump, code: cc)) prepayment on \(target.name) saves \(currencyCompact(interestSaved, code: cc)) in interest and closes it \(monthsSaved) month\(monthsSaved == 1 ? "" : "s") sooner.",
            actionLabel: "Explore",
            loanID: target.id,
            score: scoreFromSavings(interestSaved)
        )]
    }

    /// Encouragement when the user is ahead of schedule on any loan.
    private static func aheadOfScheduleNudges(_ loans: [Loan]) -> [Nudge] {
        for loan in loans {
            guard let status = loan.scheduleStatus, status.contains("ahead") else { continue }
            let ahead = loan.totalMonthsPaid - loan.expectedMonthsPaidByNow
            guard ahead > 0 else { continue }

            return [Nudge(
                id: "\(NudgeKind.aheadOfSchedule.rawValue)-\(loan.id.uuidString)",
                kind: .aheadOfSchedule,
                title: "Nice work",
                icon: "hands.clap.fill",
                tint: .progress,
                message: "You're \(ahead) month\(ahead == 1 ? "" : "s") ahead on \(loan.name). Keep the momentum.",
                actionLabel: nil,
                loanID: loan.id,
                score: 10 + min(ahead, 20)
            )]
        }
        return []
    }

    /// Loans closing within the next 12 months — flag the freed-up cash flow.
    private static func loanClosingSoonNudges(_ loans: [Loan]) -> [Nudge] {
        let closingSoon = loans
            .compactMap { loan -> (loan: Loan, months: Int)? in
                guard let proj = loan.projection(extraLumpSum: 0, extraMonthly: 0) else { return nil }
                let months = Int(ceil(proj.monthsRemaining))
                guard months > 0, months <= 12 else { return nil }
                return (loan, months)
            }
            .min(by: { $0.months < $1.months })

        guard let target = closingSoon else { return [] }

        return [Nudge(
            id: "\(NudgeKind.loanClosingSoon.rawValue)-\(target.loan.id.uuidString)",
            kind: .loanClosingSoon,
            title: "Almost there",
            icon: "flag.checkered",
            tint: .milestone,
            message: "\(target.loan.name) closes in \(target.months) month\(target.months == 1 ? "" : "s"). You'll free up \(currencyCompact(target.loan.monthlyPayment, code: target.loan.currencyCode))/mo after that.",
            actionLabel: nil,
            loanID: target.loan.id,
            score: 25 - target.months   // sooner = higher score
        )]
    }

    /// Crossed 25/50/75% on any loan — celebrate.
    private static func milestoneNudges(_ loans: [Loan]) -> [Nudge] {
        for loan in loans {
            let pct = Int(loan.progressFraction * 100)
            // Trigger when we're within 2pp of a major threshold (so it doesn't trigger
            // at exactly 25.000001%, but at 25-26%, 50-51%, 75-76%).
            let milestones = [25, 50, 75]
            for m in milestones where pct >= m && pct <= m + 2 {
                return [Nudge(
                    id: "\(NudgeKind.milestone.rawValue)-\(loan.id.uuidString)-\(m)",
                    kind: .milestone,
                    title: "Milestone",
                    icon: "star.fill",
                    tint: .milestone,
                    message: "You've paid off \(m)% of \(loan.name). \(milestoneFlavor(m))",
                    actionLabel: nil,
                    loanID: loan.id,
                    score: 15
                )]
            }
        }
        return []
    }

    private static func milestoneFlavor(_ pct: Int) -> String {
        switch pct {
        case 25: return "A quarter down."
        case 50: return "Halfway there."
        case 75: return "Three quarters done."
        default: return ""
        }
    }

    // MARK: - Scoring & formatting

    /// Convert interest savings to a score. Logarithmic-ish so a 5K save
    /// and a 50K save don't differ by 10x — they differ by ~2x.
    private static func scoreFromSavings(_ amount: Double) -> Int {
        50 + Int(log10(max(1, amount / 100)) * 15)
    }

    /// Format an amount with the loan's currency symbol, compact and rounded.
    private static func currencyCompact(_ value: Double, code: String) -> String {
        let formatted = value.formatted(.currency(code: code).precision(.fractionLength(0)))
        return formatted
    }

    /// Sensible rounding unit for suggested amounts based on currency.
    /// For high-denomination currencies (INR, JPY, KRW) use larger steps;
    /// for USD/EUR/GBP use smaller steps.
    private static func roundingUnit(for code: String, emi: Double) -> Double {
        switch code {
        case "JPY", "KRW", "VND", "IDR":
            return max(1000, (emi * 0.01).rounded(.up))
        case "INR":
            return 500
        default:
            // USD, EUR, GBP, AUD, CAD, etc.
            return max(50, ((emi * 0.05) / 50).rounded() * 50)
        }
    }

    // MARK: - Dismissal tracking

    private static let cooldownDays = 7

    static func dismiss(_ nudge: Nudge) {
        UserDefaults.standard.set(Date(), forKey: dismissalKey(for: nudge))
    }

    static func isDismissed(_ nudge: Nudge) -> Bool {
        guard let dismissedAt = UserDefaults.standard.object(forKey: dismissalKey(for: nudge)) as? Date else {
            return false
        }
        let cooldown = TimeInterval(cooldownDays * 24 * 60 * 60)
        return Date().timeIntervalSince(dismissedAt) < cooldown
    }

    private static func dismissalKey(for nudge: Nudge) -> String {
        "nudge_dismissed_\(nudge.id)"
    }
}

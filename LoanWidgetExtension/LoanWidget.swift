import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

// MARK: - Shared

/// Plain-data snapshot of a Loan, safe to pass through TimelineEntry.
/// We don't hand SwiftData @Model objects to widget views directly because
/// they're tied to a specific ModelContext lifecycle.
struct LoanSnapshot: Identifiable, Hashable {
    let id: String
    let name: String
    let remaining: Double
    let principal: Double
    let progress: Double
    let monthsPaid: Int
    let tenureMonths: Int
    let monthlyPayment: Double
    let annualInterestRate: Double   // needed for accurate close-date projection
    let nextEMIDate: Date?
    let daysUntilNextEMI: Int?
    let iconKey: String              // SF Symbol-backed key for the loan icon
    let isPinned: Bool
    let missedEMIs: Int              // 0 = on track; >0 = behind schedule
    let currencyCode: String         // ISO 4217 — "INR", "USD", "EUR", etc.
}

private let appGroupID = "group.com.app.simple-loan-tracker"

/// Format days-until-EMI consistently across widgets.
/// - 0: "Today"
/// - negative: "Overdue 5d"
/// - positive: "in 3d"
func emiDaysLabel(_ days: Int?) -> String {
    guard let d = days else { return "—" }
    if d == 0 { return "Today" }
    if d < 0  { return "Overdue \(-d)d" }
    return "in \(d)d"
}

/// Just the raw days/short suffix, no prefix. For tight UIs.
func emiDaysShort(_ days: Int?) -> String {
    guard let d = days else { return "—" }
    if d == 0 { return "Today" }
    if d < 0  { return "Overdue" }
    return "\(d)d"
}

/// Color cue for upcoming/overdue EMI.
func emiDaysColor(_ days: Int?) -> Color {
    guard let d = days else { return .secondary }
    if d < 0 { return .red }
    if d <= 3 { return .orange }
    return .secondary
}

// MARK: - App Intent (widget configuration)

/// Represents a Loan choice in the widget's configuration picker.
struct LoanEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Loan"
    static var defaultQuery = LoanQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    /// Sentinel id used to mean "track all loans" rather than a specific one.
    static let allLoansID = "__all__"
    static let allLoans = LoanEntity(id: allLoansID, name: "All Loans")
}

/// Tells iOS which loans are available to pick from.
struct LoanQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LoanEntity] {
        var results: [LoanEntity] = []
        if identifiers.contains(LoanEntity.allLoansID) {
            results.append(.allLoans)
        }
        results.append(contentsOf:
            loadLoanSnapshots()
                .filter { identifiers.contains($0.id) }
                .map { LoanEntity(id: $0.id, name: $0.name) }
        )
        return results
    }

    func suggestedEntities() async throws -> [LoanEntity] {
        // "All Loans" first, then individual loans.
        [.allLoans] + loadLoanSnapshots().map { LoanEntity(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> LoanEntity? {
        .allLoans
    }
}

/// The widget's configurable parameters.
struct SelectLoanIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Loan"
    static var description = IntentDescription("Pick a specific loan to track, or leave empty for overall progress.")

    @Parameter(title: "Loan")
    var loan: LoanEntity?
}

/// Load all loans from the shared SwiftData store and convert to snapshots.
/// Each widget provider calls this when computing its timeline.
private func loadLoanSnapshots() -> [LoanSnapshot] {
    let schema = Schema([Loan.self, Payment.self, RateChange.self])
    let config = ModelConfiguration(
        "LoanTracker",
        schema: schema,
        groupContainer: .identifier(appGroupID)
    )

    do {
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Loan>(sortBy: [SortDescriptor(\.createdAt)])
        let loans = try context.fetch(descriptor)

        return loans.map { loan in
            LoanSnapshot(
                id: loan.id.uuidString,
                name: loan.name,
                remaining: loan.remainingBalance,
                principal: loan.principal,
                progress: loan.progressFraction,
                monthsPaid: loan.totalMonthsPaid,
                tenureMonths: loan.tenureMonths,
                monthlyPayment: loan.monthlyPayment,
                annualInterestRate: loan.annualInterestRate,
                nextEMIDate: loan.nextEMIDate,
                daysUntilNextEMI: loan.daysUntilNextEMI,
                iconKey: loan.iconKey,
                isPinned: loan.isPinned,
                missedEMIs: loan.missedEMIs ?? 0,
                currencyCode: loan.currencyCode
            )
        }
    } catch {
        print("⚠️ [Widget] Container/fetch error: \(error)")
        return []
    }
}

/// Latest projected close date across all active loans — the "debt-free by" date.
/// Uses closed-form amortization (same formula as the Loan model) so the
/// widget matches what the detail screen shows.
private func debtFreeDate(from snapshots: [LoanSnapshot]) -> Date? {
    let active = snapshots.filter { $0.remaining > 0.01 }
    guard !active.isEmpty else { return nil }

    let approximate = active.compactMap { snap -> Date? in
        let monthsLeft = monthsToPayoff(
            balance: snap.remaining,
            monthlyPayment: snap.monthlyPayment,
            annualRate: snap.annualInterestRate
        )
        guard let m = monthsLeft else { return nil }
        // Anchor from the next EMI date if known, else from today.
        let anchor = snap.nextEMIDate ?? .now
        return Calendar.current.date(byAdding: .month, value: m, to: anchor)
    }
    return approximate.max()
}

/// Solve standard amortization for n: how many monthly payments will clear the
/// balance, given the monthly interest rate?
///
/// Formula: n = -ln(1 - r·B/M) / ln(1 + r)
/// where r = monthlyRate, B = balance, M = monthly payment.
/// Returns nil if the EMI doesn't cover the monthly interest (loan never closes).
private func monthsToPayoff(balance: Double, monthlyPayment: Double, annualRate: Double) -> Int? {
    guard balance > 0, monthlyPayment > 0 else { return nil }
    let r = annualRate / 12.0
    if r <= 0 {
        // Zero-interest loan: simple division.
        return Int(ceil(balance / monthlyPayment))
    }
    let denominator = monthlyPayment - r * balance
    guard denominator > 0 else {
        // EMI doesn't even cover the monthly interest — loan never amortizes.
        return nil
    }
    let n = -log(1 - r * balance / monthlyPayment) / log(1 + r)
    guard n.isFinite, n > 0 else { return nil }
    return Int(ceil(n))
}

/// How often each widget refreshes. Balance only meaningfully changes on payments,
/// and the app already calls refreshWidget() on writes — so 6 hours is comfortable.
private let widgetRefreshInterval: TimeInterval = 6 * 60 * 60

/// Currency format helpers — use the loan's own currency code so amounts
/// display correctly for any country (INR, USD, EUR, GBP, JPY, etc.).
extension FormatStyle where Self == FloatingPointFormatStyle<Double>.Currency {
    static func compact(code: String) -> FloatingPointFormatStyle<Double>.Currency {
        .currency(code: code).precision(.fractionLength(0)).notation(.compactName)
    }
    static func full(code: String) -> FloatingPointFormatStyle<Double>.Currency {
        .currency(code: code).precision(.fractionLength(0))
    }
    // Legacy convenience — used by overview widgets that aggregate across currencies
    static var inrCompact: FloatingPointFormatStyle<Double>.Currency {
        .compact(code: "INR")
    }
    static var inrFull: FloatingPointFormatStyle<Double>.Currency {
        .full(code: "INR")
    }
}

// MARK: - Overview Widget

struct OverviewEntry: TimelineEntry {
    let date: Date
    let totalRemaining: Double
    let monthlyEMITotal: Double
    let activeLoanCount: Int
    let debtFreeBy: Date?
    /// Unified currency code when all active loans share the same currency; nil if mixed.
    let currencyCode: String?
}

struct OverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry {
        OverviewEntry(
            date: .now,
            totalRemaining: 2_724_962,
            monthlyEMITotal: 41_131,
            activeLoanCount: 3,
            debtFreeBy: Calendar.current.date(byAdding: .month, value: 24, to: .now),
            currencyCode: "INR"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (OverviewEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OverviewEntry>) -> Void) {
        let entry = load()
        let next = Date().addingTimeInterval(widgetRefreshInterval)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> OverviewEntry {
        let snaps = loadLoanSnapshots()
        let active = snaps.filter { $0.remaining > 0.01 }
        let currencies = Set(active.map(\.currencyCode))
        let unified = currencies.count == 1 ? currencies.first : nil
        return OverviewEntry(
            date: .now,
            totalRemaining: active.reduce(0) { $0 + $1.remaining },
            monthlyEMITotal: active.reduce(0) { $0 + $1.monthlyPayment },
            activeLoanCount: active.count,
            debtFreeBy: debtFreeDate(from: snaps),
            currencyCode: unified
        )
    }
}

struct OverviewWidgetView: View {
    let entry: OverviewEntry
    @Environment(\.widgetFamily) var family

    /// Currency format for amounts — uses the unified currency if all loans
    /// share the same one, otherwise falls back to INR.
    private var compactFormat: FloatingPointFormatStyle<Double>.Currency {
        .compact(code: entry.currencyCode ?? "INR")
    }

    var body: some View {
        Group {
            if family == .systemMedium {
                mediumLayout
            } else {
                smallLayout
            }
        }
        .widgetURL(URL(string: "loantracker://home"))
    }

    // MARK: - Small (single column, top-anchored, count pinned to bottom)

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Total Remaining")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(entry.totalRemaining, format: compactFormat)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            if entry.monthlyEMITotal > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("EMI/mo:")
                        .foregroundStyle(.secondary)
                    Text(entry.monthlyEMITotal, format: compactFormat)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }

            if let date = entry.debtFreeBy {
                debtFreePill(date)
            }

            if entry.activeLoanCount > 0 {
                Text("\(entry.activeLoanCount) loan\(entry.activeLoanCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Medium (two columns: balance on left, EMI + debt-free on right)

    private var mediumLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            // LEFT — current state ("what I owe")
            VStack(alignment: .leading, spacing: 6) {
                Text("Total Remaining")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(entry.totalRemaining, format: compactFormat)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if entry.activeLoanCount > 0 {
                    Text("\(entry.activeLoanCount) active loan\(entry.activeLoanCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Vertical divider — subtle hairline to tie the two columns together.
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1)

            // RIGHT — cash flow & future ("what's happening")
            VStack(alignment: .leading, spacing: 6) {
                if entry.monthlyEMITotal > 0 {
                    Text("Monthly EMI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(entry.monthlyEMITotal, format: compactFormat)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }

                if let date = entry.debtFreeBy {
                    debtFreePill(date)
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Shared

    private func debtFreePill(_ date: Date) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.caption2)
            Text("Free by \(date.formatted(.dateTime.month(.abbreviated).year()))")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.18))
        .foregroundStyle(.green)
        .clipShape(Capsule())
    }
}

struct OverviewWidget: Widget {
    let kind = "OverviewWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OverviewProvider()) { entry in
            OverviewWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Loan Overview")
        .description("Total remaining and your debt-free date at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Loan List Widget

struct LoanListEntry: TimelineEntry {
    let date: Date
    let loans: [LoanSnapshot]
}

struct LoanListProvider: TimelineProvider {
    func placeholder(in context: Context) -> LoanListEntry {
        LoanListEntry(date: .now, loans: [
            LoanSnapshot(id: "1", name: "Home Loan", remaining: 1_954_000, principal: 2_500_000,
                         progress: 0.22, monthsPaid: 12, tenureMonths: 240, monthlyPayment: 25_000,
                         annualInterestRate: 0.085, nextEMIDate: nil, daysUntilNextEMI: nil,
                         iconKey: "home", isPinned: true, missedEMIs: 0, currencyCode: "INR"),
            LoanSnapshot(id: "2", name: "Car Loan", remaining: 369_547, principal: 500_000,
                         progress: 0.26, monthsPaid: 9, tenureMonths: 36, monthlyPayment: 16_131,
                         annualInterestRate: 0.0999, nextEMIDate: nil, daysUntilNextEMI: nil,
                         iconKey: "car", isPinned: false, missedEMIs: 0, currencyCode: "INR"),
            LoanSnapshot(id: "3", name: "Personal", remaining: 401_415, principal: 500_000,
                         progress: 0.20, monthsPaid: 8, tenureMonths: 36, monthlyPayment: 16_131,
                         annualInterestRate: 0.0999, nextEMIDate: nil, daysUntilNextEMI: nil,
                         iconKey: "person", isPinned: false, missedEMIs: 0, currencyCode: "INR")
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (LoanListEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LoanListEntry>) -> Void) {
        let entry = load()
        let next = Date().addingTimeInterval(widgetRefreshInterval)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> LoanListEntry {
        // Priority order for the limited widget rows:
        // 1. Pinned loans float to top (consistent with the app's home screen)
        // 2. Then loans with missed EMIs / overdue — needs visibility on the lock screen
        // 3. Then by soonest next EMI date — actionable proximity
        let sorted = loadLoanSnapshots()
            .filter { $0.remaining > 0.01 }
            .sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                let aOverdue = a.missedEMIs > 0
                let bOverdue = b.missedEMIs > 0
                if aOverdue != bOverdue { return aOverdue }
                let aDays = a.daysUntilNextEMI ?? Int.max
                let bDays = b.daysUntilNextEMI ?? Int.max
                return aDays < bDays
            }
        return LoanListEntry(date: .now, loans: sorted)
    }
}

struct LoanListWidgetView: View {
    let entry: LoanListEntry
    @Environment(\.widgetFamily) var family

    private var visibleLoans: ArraySlice<LoanSnapshot> {
        entry.loans.prefix(family == .systemMedium ? 2 : 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Loans")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Link(destination: URL(string: "loantracker://add-payment")!) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
            }

            if entry.loans.isEmpty {
                Spacer()
                Text("No active loans")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(visibleLoans) { loan in
                    LoanRowView(loan: loan, showDetail: family == .systemLarge)
                }
                if entry.loans.count > visibleLoans.count {
                    Text("+\(entry.loans.count - visibleLoans.count) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .widgetURL(URL(string: "loantracker://home"))
    }
}

/// SF Symbol name for an icon key. Mirrors LoanIcon in the main app, kept
/// local here because the widget extension target doesn't import the app code.
private func widgetIconSymbol(_ key: String) -> String {
    switch key {
    case "home":      return "house.fill"
    case "car":       return "car.fill"
    case "bike":      return "bicycle"
    case "person":    return "person.crop.circle.fill"
    case "business":  return "briefcase.fill"
    case "education": return "graduationcap.fill"
    case "medical":   return "cross.case.fill"
    case "gold":      return "circle.hexagongrid.fill"
    case "card":      return "creditcard.fill"
    default:          return "banknote.fill"
    }
}

private struct LoanRowView: View {
    let loan: LoanSnapshot
    let showDetail: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Icon column — small, accent-tinted to match the app's home screen
            Image(systemName: widgetIconSymbol(loan.iconKey))
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if loan.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .padding(.top, 2)
                            .foregroundStyle(.orange)
                    }
                    Text(loan.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if loan.missedEMIs > 0 {
                        Text("\(loan.missedEMIs)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.2))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(loan.remaining, format: .compact(code: loan.currencyCode))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                ProgressView(value: loan.progress)
                    .tint(.accentColor)
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)
                if showDetail {
                    HStack(spacing: 4) {
                        if loan.tenureMonths > 0 {
                            Text("\(loan.monthsPaid)/\(loan.tenureMonths)")
                        }
                        if let days = loan.daysUntilNextEMI {
                            Text("•")
                            Text("EMI \(emiDaysLabel(days))")
                                .foregroundStyle(emiDaysColor(days))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct LoanListWidget: Widget {
    let kind = "LoanListWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LoanListProvider()) { entry in
            LoanListWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Loans List")
        .description("All your loans with progress bars. Tap + to log a payment.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Next EMI Widget

struct NextEMIEntry: TimelineEntry {
    let date: Date
    let upcoming: LoanSnapshot?       // Soonest upcoming EMI
    let followUps: [LoanSnapshot]     // The next 1-2 after that, for medium size
}

struct NextEMIProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEMIEntry {
        let next = Calendar.current.date(byAdding: .day, value: 7, to: .now)
        return NextEMIEntry(
            date: .now,
            upcoming: LoanSnapshot(
                id: "1", name: "Personal Loan", remaining: 401_415, principal: 500_000,
                progress: 0.2, monthsPaid: 8, tenureMonths: 36, monthlyPayment: 16_131,
                annualInterestRate: 0.0999, nextEMIDate: next, daysUntilNextEMI: 7,
                iconKey: "person", isPinned: false, missedEMIs: 0, currencyCode: "INR"
            ),
            followUps: []
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NextEMIEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEMIEntry>) -> Void) {
        let entry = load()
        // Refresh more often than 6h here since the day-count changes daily.
        let next = Calendar.current.startOfDay(for: Date().addingTimeInterval(24 * 60 * 60))
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> NextEMIEntry {
        let withEMI = loadLoanSnapshots()
            .filter { $0.daysUntilNextEMI != nil }
            .sorted { ($0.daysUntilNextEMI ?? Int.max) < ($1.daysUntilNextEMI ?? Int.max) }
        return NextEMIEntry(
            date: .now,
            upcoming: withEMI.first,
            followUps: Array(withEMI.dropFirst().prefix(2))
        )
    }
}

struct NextEMIWidgetView: View {
    let entry: NextEMIEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if let loan = entry.upcoming {
                if family == .systemMedium {
                    mediumLayout(loan: loan)
                } else {
                    smallLayout(loan: loan)
                }
            } else {
                emptyState
            }
        }
        .widgetURL(URL(string: "loantracker://home"))
    }

    // MARK: - Small (single column, day-count hero)

    private func smallLayout(loan: LoanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Next EMI")
                .font(.caption2)
                .foregroundStyle(.secondary)

            dayCountView(loan: loan, large: true)

            Spacer(minLength: 0)

            Text(loan.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(loan.monthlyPayment, format: .full(code: loan.currencyCode))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Medium (two columns: primary EMI left, follow-ups right)

    private func mediumLayout(loan: LoanSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // LEFT — primary upcoming EMI
            VStack(alignment: .leading, spacing: 6) {
                Text("Next EMI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                dayCountView(loan: loan, large: true)

                Spacer(minLength: 0)

                Text(loan.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(loan.monthlyPayment, format: .full(code: loan.currencyCode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // RIGHT — follow-ups list, or fallback message if there are none
            if !entry.followUps.isEmpty {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Upcoming")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(entry.followUps) { f in
                        HStack(alignment: .firstTextBaseline) {
                            Text(f.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer(minLength: 4)
                            if let d = f.daysUntilNextEMI {
                                Text(emiDaysShort(d))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(emiDaysColor(d))
                                    .monospacedDigit()
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Day-count subview (shared between small + medium)

    @ViewBuilder
    private func dayCountView(loan: LoanSnapshot, large: Bool) -> some View {
        if let days = loan.daysUntilNextEMI {
            if days == 0 {
                Text("Today")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
            } else if days < 0 {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Overdue")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.red)
                    Text("\(-days) \(abs(days) == 1 ? "day" : "days")")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(days)")
                        .font(.system(size: large ? 36 : 28, weight: .bold, design: .rounded))
                        .foregroundStyle(days <= 3 ? .orange : .primary)
                    Text(days == 1 ? "day" : "days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Empty state (no upcoming EMIs)

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.title)
                .foregroundStyle(.green)
            Text("No upcoming EMIs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NextEMIWidget: Widget {
    let kind = "NextEMIWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextEMIProvider()) { entry in
            NextEMIWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next EMI")
        .description("Countdown to your soonest upcoming EMI.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Quick Add Payment Widget

struct AddPaymentEntry: TimelineEntry {
    let date: Date
    let loanCount: Int
}

struct AddPaymentProvider: TimelineProvider {
    func placeholder(in context: Context) -> AddPaymentEntry {
        AddPaymentEntry(date: .now, loanCount: 3)
    }
    func getSnapshot(in context: Context, completion: @escaping (AddPaymentEntry) -> Void) {
        completion(load())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AddPaymentEntry>) -> Void) {
        let entry = load()
        let next = Date().addingTimeInterval(widgetRefreshInterval)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
    private func load() -> AddPaymentEntry {
        AddPaymentEntry(date: .now, loanCount: loadLoanSnapshots().filter { $0.remaining > 0.01 }.count)
    }
}

struct AddPaymentWidgetView: View {
    let entry: AddPaymentEntry

    var body: some View {
        Link(destination: URL(string: "loantracker://add-payment")!) {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Add Payment")
                    .font(.callout.weight(.semibold))
                Text("\(entry.loanCount) loan\(entry.loanCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AddPaymentWidget: Widget {
    let kind = "AddPaymentWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AddPaymentProvider()) { entry in
            AddPaymentWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Add Payment")
        .description("One-tap shortcut to log a payment.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Progress Ring (small, configurable)

struct RingEntry: TimelineEntry {
    let date: Date
    let snapshots: [LoanSnapshot]
    let selectedLoanID: String?    // nil = "All loans" (aggregate)
}

struct RingProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RingEntry {
        RingEntry(date: .now, snapshots: [
            LoanSnapshot(id: "1", name: "Home", remaining: 1_700_000, principal: 2_500_000,
                         progress: 0.32, monthsPaid: 12, tenureMonths: 60,
                         monthlyPayment: 25000, annualInterestRate: 0.085,
                         nextEMIDate: nil, daysUntilNextEMI: nil,
                         iconKey: "home", isPinned: false, missedEMIs: 0, currencyCode: "INR")
        ], selectedLoanID: nil)
    }

    func snapshot(for configuration: SelectLoanIntent, in context: Context) async -> RingEntry {
        RingEntry(date: .now, snapshots: loadLoanSnapshots(), selectedLoanID: configuration.loan?.id)
    }

    func timeline(for configuration: SelectLoanIntent, in context: Context) async -> Timeline<RingEntry> {
        let entry = RingEntry(date: .now, snapshots: loadLoanSnapshots(), selectedLoanID: configuration.loan?.id)
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60 * 60 * 6)))
    }
}

struct RingProgressWidgetView: View {
    let entry: RingEntry

    /// The loans this widget is currently tracking (one specific loan, or all).
    private var trackedLoans: [LoanSnapshot] {
        if let id = entry.selectedLoanID,
           id != LoanEntity.allLoansID,
           let one = entry.snapshots.first(where: { $0.id == id }) {
            return [one]
        }
        return entry.snapshots
    }

    /// Currency code used for display — if all tracked loans share a currency, use it; else INR.
    private var dominantCurrency: String {
        let codes = Set(trackedLoans.map(\.currencyCode))
        return codes.count == 1 ? (codes.first ?? "INR") : "INR"
    }

    /// Progress = 1 - remaining/principal across tracked loans.
    private var progress: Double {
        let totalP = trackedLoans.reduce(0) { $0 + $1.principal }
        let totalR = trackedLoans.reduce(0) { $0 + $1.remaining }
        guard totalP > 0 else { return 0 }
        return max(0, min(1, 1 - totalR / totalP))
    }

    private var totalRemaining: Double {
        trackedLoans.reduce(0) { $0 + $1.remaining }
    }

    /// Label shown above the ring — loan name if specific, else "All Loans".
    private var contextLabel: String {
        if trackedLoans.count == 1 {
            return trackedLoans[0].name
        }
        return "All Loans"
    }

    var body: some View {
        if trackedLoans.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                Text("Debt-free")
                    .font(.caption.weight(.semibold))
            }
        } else {
            ZStack {
                Circle()
                    .stroke(lineWidth: 14)
                    .opacity(0.15)
                    .foregroundStyle(.green)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [.green, .mint, .teal, .green]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: progress)
                VStack(spacing: 0) {
                    Text(contextLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                   HStack(spacing: 2) {
                        Text(totalRemaining, format: .compact(code: dominantCurrency))
                            .monospacedDigit()
                        Text("left")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2.weight(.medium))
            
                }
            }
            .padding(4)
        }
    }
}

struct RingProgressWidget: Widget {
    let kind = "RingProgressWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectLoanIntent.self,
            provider: RingProvider()
        ) { entry in
            RingProgressWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Progress Ring")
        .description("Track overall progress or pick one specific loan.")
        .supportedFamilies([.systemSmall])
    }
}

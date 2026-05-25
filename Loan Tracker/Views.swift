import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts

// MARK: - Formatting

/// Compact Indian-rupee formatting for tight spaces.
/// Used as a fallback when the full grouped format ("₹21,28,216.00") doesn't fit.
/// - 1 Cr+ → "₹1.5Cr"
/// - 1 L+  → "₹4.0L"
/// - 1 K+  → "₹65K"
/// - else  → "₹999"
func compactINR(_ amount: Double) -> String {
    let abs = Swift.abs(amount)
    if abs >= 10_000_000 { return String(format: "₹%.1fCr", amount / 10_000_000) }
    if abs >= 100_000    { return String(format: "₹%.1fL", amount / 100_000) }
    if abs >= 1_000      { return "₹\(Int(amount / 1_000))K" }
    return "₹\(Int(amount))"
}

// MARK: - Home

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Loan.createdAt) private var allLoans: [Loan]
    @State private var showingAddLoan = false
    @State private var showingAddPayment = false
    @State private var quickPayLoan: Loan?  // when set, opens AddPayment pre-filled
    @State private var showingExportSheet = false
    @State private var showingImportSheet = false
    @State private var showingSettings = false        // ← add this
    @State private var nudgeTargetLoan: Loan?         // drill-down target from a nudge tap
    @State private var nudgeTargetKind: NudgeKind?    // tracks which kind triggered the drill-down
    @State private var nudgeRefreshTrigger = UUID()   // bumped on dismiss to recompute
    @Binding var deepLinkRoute: DeepLinkRoute?
    @Namespace private var loanNamespace

    /// Pinned loans float to the top, then chronological by creation.
    /// Sorted in-memory since SwiftData's SortDescriptor doesn't accept Bool.
    private var loans: [Loan] {
        allLoans.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.createdAt < b.createdAt
        }
    }

    private var totalRemaining: Double {
        loans.reduce(0) { $0 + $1.remainingBalance }
    }

    /// Sum of EMIs across active loans — what the user must set aside each month.
    private var totalMonthlyEMI: Double {
        loans.filter { $0.remainingBalance > 0.01 }.reduce(0) { $0 + $1.monthlyPayment }
    }

    /// Overall debt-paydown progress across all loans, 0...1.
    /// Total principal minus total remaining, divided by total principal.
    private var totalProgress: Double {
        let totalPrincipal = loans.reduce(0.0) { $0 + $1.principal }
        guard totalPrincipal > 0 else { return 0 }
        let totalPaid = totalPrincipal - totalRemaining
        return min(1.0, max(0.0, totalPaid / totalPrincipal))
    }

    /// Loans with non-zero remaining balance, sorted by balance descending.
    /// Each pair carries the loan and its fraction of the total remaining debt
    /// — used by the composition bar to visualize "where my debt sits."
    private var activeBreakdown: [(loan: Loan, fraction: Double)] {
        let active = loans.filter { $0.remainingBalance > 0.01 }
        let total = active.reduce(0.0) { $0 + $1.remainingBalance }
        guard total > 0 else { return [] }
        return active
            .sorted { $0.remainingBalance > $1.remainingBalance }
            .map { ($0, $0.remainingBalance / total) }
    }

    /// Best nudge to show right now. `nudgeRefreshTrigger` participates in the
    /// dependency graph so that dismissals re-evaluate the candidate list.
    private var currentNudge: Nudge? {
        _ = nudgeRefreshTrigger
        return NudgeEngine.topNudge(for: loans)
    }

    /// The date when the user's last active loan is projected to close.
    /// nil if no active loans, or if any loan can't be projected (EMI doesn't cover interest).
    private var debtFreeDate: Date? {
        let active = loans.filter { $0.remainingBalance > 0.01 }
        guard !active.isEmpty else { return nil }
        let closeDates = active.compactMap { $0.estimatedCloseDate }
        guard closeDates.count == active.count else { return nil }
        return closeDates.max()
    }

    /// All payments across all loans, sorted by most recent.
    /// Limit shown on home to keep the list focused.
    private var recentPayments: [Payment] {
        loans.flatMap { $0.payments }
            .sorted { $0.date > $1.date }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Remaining")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(totalRemaining, format: .currency(code: "INR"))
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .minimumScaleFactor(0.7)
                                .lineLimit(1)
                        }

                        if totalMonthlyEMI > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar.circle.fill")
                                    .foregroundStyle(.secondary)
                                Text("Monthly EMIs:")
                                    .foregroundStyle(.secondary)
                                Text(totalMonthlyEMI, format: .currency(code: "INR").precision(.fractionLength(0)))
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                        }

                        if let date = debtFreeDate {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar.badge.checkmark")
                                Text("Debt-free by \(date.formatted(.dateTime.month(.abbreviated).year()))")
                            }
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                        }

                        // Composition bar — proportional segments showing how the
                        // total debt breaks down across loans. Only meaningful for
                        // 2+ active loans (single loan would be a solid bar).
                        if activeBreakdown.count > 1 {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("By Loan")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(activeBreakdown.count) active")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                GeometryReader { geo in
                                    HStack(spacing: 2) {
                                        ForEach(Array(activeBreakdown.enumerated()), id: \.element.loan.id) { idx, item in
                                            Rectangle()
                                                .fill(Color.accentColor.opacity(opacityForBreakdownIndex(idx, total: activeBreakdown.count)))
                                                .frame(width: max(2, geo.size.width * item.fraction))
                                        }
                                    }
                                }
                                .frame(height: 10)
                                .clipShape(Capsule())

                                // Inline legend: dot + name + percent for each loan.
                                // Wraps naturally if many loans.
                                HStack(spacing: 10) {
                                    ForEach(Array(activeBreakdown.enumerated()), id: \.element.loan.id) { idx, item in
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(Color.accentColor.opacity(opacityForBreakdownIndex(idx, total: activeBreakdown.count)))
                                                .frame(width: 7, height: 7)
                                            Text(item.loan.name)
                                                .lineLimit(1)
                                            Text("\(Int(item.fraction * 100))%")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .font(.caption2)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if loans.isEmpty {
                    ContentUnavailableView(
                        "No loans yet",
                        systemImage: "indianrupeesign.circle",
                        description: Text("Tap + to add your first loan.")
                    )
                } else {
                    // Nudge — at most one card, contextually computed from the data.
                    // Sits between the hero and the loan list so it's visible but
                    // doesn't dominate. Dismissable with a 7-day cooldown.
                    if let nudge = currentNudge {
                        Section {
                            NudgeCard(
                                nudge: nudge,
                                onTap: {
                                    // Drill into the relevant loan if there is one.
                                    if let id = nudge.loanID,
                                       let target = loans.first(where: { $0.id == id }) {
                                        nudgeTargetKind = nudge.kind
                                        nudgeTargetLoan = target
                                    }
                                },
                                onDismiss: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                        NudgeEngine.dismiss(nudge)
                                        nudgeRefreshTrigger = UUID()
                                    }
                                }
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }

                    Section("Loans") {
                        ForEach(loans) { loan in
                            NavigationLink {
                                LoanDetailView(loan: loan)
                                    .navigationTransition(.zoom(sourceID: loan.persistentModelID, in: loanNamespace))
                            } label: {
                                LoanRow(loan: loan)
                            }
                            .matchedTransitionSource(id: loan.persistentModelID, in: loanNamespace)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if loan.remainingBalance > 0.01 {
                                    Button {
                                        quickPayLoan = loan
                                    } label: {
                                        Label("Pay EMI", systemImage: "indianrupeesign.circle.fill")
                                    }
                                    .tint(.green)
                                }
                                Button {
                                    togglePin(loan)
                                } label: {
                                    Label(loan.isPinned ? "Unpin" : "Pin",
                                          systemImage: loan.isPinned ? "pin.slash" : "pin")
                                }
                                .tint(.orange)
                            }
                        }
                        .onDelete(perform: deleteLoans)
                        // Smoothly animate row reordering when a loan is pinned/unpinned.
                        // Keyed to the loan-id order so SwiftUI only triggers on
                        // actual order changes, not on every render.
                        .animation(.spring(response: 0.45, dampingFraction: 0.85),
                                   value: loans.map { $0.id })
                    }

                    if !recentPayments.isEmpty {
                        Section("Recent Activity") {
                            ForEach(recentPayments) { payment in
                                RecentPaymentRow(payment: payment)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Loans")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("₹")
                        .font(.custom("PlayfairDisplayRoman-Bold", size: 22))
                        .foregroundStyle(.primary)
                        .logoAnchor()
                }
                ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add Payment", systemImage: "plus.circle") {
                            showingAddPayment = true
                        }
                        Button("Add Loan", systemImage: "doc.badge.plus") {
                            showingAddLoan = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddLoan) { LoanFormView() }
            .sheet(isPresented: $showingAddPayment) {
                AddPaymentView(loans: loans)
            }
            .sheet(item: $quickPayLoan) { loan in
                AddPaymentView(loans: [loan], preselected: loan, defaultAmount: loan.monthlyPayment)
            }
            .sheet(isPresented: $showingExportSheet) {
                ExportBackupSheet(loans: loans)
            }
            .sheet(isPresented: $showingImportSheet) {
                ImportBackupSheet()
            }.sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .navigationDestination(item: $nudgeTargetLoan) { loan in
                // Auto-scroll to the Playground only for nudges that suggest a
                // prepayment action — others (ahead/closing/milestone) drill in
                // without scrolling.
                let shouldScroll = nudgeTargetKind == .prepaymentImpact
                                || nudgeTargetKind == .lumpSumImpact
                LoanDetailView(loan: loan, autoScrollToPlayground: shouldScroll)
            }
            .onChange(of: deepLinkRoute) { _, newRoute in
                guard let newRoute else { return }
                switch newRoute {
                case .addPayment: showingAddPayment = true
                case .addLoan:    showingAddLoan = true
                }
                deepLinkRoute = nil
            }
            .onAppear {
                // Also fire a widget refresh on every launch
                refreshWidget()
                refreshNotifications(loans: loans)
            }
        }
    }

    /// Opacity for each breakdown segment — largest loan = 1.0, smallest ≈ 0.6.
    /// Creates visible differentiation without using multiple hues.
    private func opacityForBreakdownIndex(_ idx: Int, total: Int) -> Double {
        guard total > 1 else { return 1.0 }
        let step = 0.4 / Double(total - 1)
        return 1.0 - (Double(idx) * step)
    }

    private func deleteLoans(at offsets: IndexSet) {
        for index in offsets { context.delete(loans[index]) }
        try? context.save()
        refreshWidget()
        refreshNotifications(loans: loans)
    }

    /// Pin or unpin a loan. Only one loan stays pinned at a time — pinning
    /// a new loan automatically unpins any others.
    private func togglePin(_ loan: Loan) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            let wasPinned = loan.isPinned
            if !wasPinned {
                for other in loans where other.isPinned {
                    other.isPinned = false
                }
            }
            loan.isPinned.toggle()
        }
        try? context.save()
    }
}

struct LoanRow: View {
    let loan: Loan

    private var icon: LoanIcon { LoanIcon.resolve(loan.iconKey) }

    /// Color for the status text (ahead/behind/on schedule).
    private var statusColor: Color {
        guard let status = loan.scheduleStatus else { return .secondary }
        if status.contains("ahead")  { return .green }
        if status.contains("behind") { return .red }
        return .secondary
    }

    /// Compact symbol that goes with the status text.
    private var statusSymbol: String? {
        guard let status = loan.scheduleStatus else { return nil }
        if status.contains("ahead")  { return "arrow.up.right" }
        if status.contains("behind") { return "arrow.down.right" }
        return "checkmark"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            Image(systemName: icon.systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                // Title row: pin + name + missed badge + balance
                HStack(spacing: 6) {
                    if loan.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .padding(.top, 2)
                            .foregroundStyle(.orange)
                    }
                    Text(loan.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let missed = loan.missedEMIs, missed > 0 {
                        Text("\(missed) missed")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    // Show the full grouped format when it fits; fall back to
                    // compact (₹4.0L, ₹21.3L, ₹1.5Cr) when the row is tight.
                    ViewThatFits(in: .horizontal) {
                        Text(loan.remainingBalance, format: .currency(code: "INR"))
                            .font(.subheadline.bold())
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(compactINR(loan.remainingBalance))
                            .font(.subheadline.bold())
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                }

                ProgressView(value: loan.progressFraction)
                    .tint(.accentColor)

                // Meta row: paid count + status + next EMI
                HStack(spacing: 2) {
                    if loan.tenureMonths > 0 {
                        Text("\(loan.totalMonthsPaid)/\(loan.tenureMonths) paid")
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        Text("\(loan.totalMonthsPaid) paid")
                            .lineLimit(1)
                            .fixedSize()
                    }

                    if let status = loan.scheduleStatus, let symbol = statusSymbol {
                        Text("·").foregroundStyle(.tertiary)
                        HStack(spacing: 2) {
                            Image(systemName: symbol)
                            Text(status)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(statusColor)
                    }

                    Spacer(minLength: 4)

                    if let next = loan.nextEMIDate, let days = loan.daysUntilNextEMI {
                        Text(days == 0 ? "Today" : "\(next, format: .dateTime.day().month(.abbreviated)) · \(days)d")
                            .foregroundStyle(days <= 3 ? .orange : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Row in the "Recent Activity" section on home.
struct RecentPaymentRow: View {
    let payment: Payment

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(payment.loan?.name ?? "—")
                    .font(.subheadline.weight(.medium))
                if let note = payment.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(payment.amount, format: .currency(code: "INR"))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(payment.date, format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Loan Detail

struct LoanDetailView: View {
    @Bindable var loan: Loan
    @Environment(\.modelContext) private var context
    @State private var showingAddPayment = false
    @State private var showingEditLoan = false
    /// When true, the view auto-scrolls to the Playground section on appear.
    /// Used when navigating in from a "try prepayment" nudge.
    var autoScrollToPlayground: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
            // MARK: Hero
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    // Icon + Remaining/Balance row
                    HStack(spacing: 12) {
                        let icon = LoanIcon.resolve(loan.iconKey)
                        Image(systemName: icon.systemImage)
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 48, height: 48)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remaining")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(loan.remainingBalance, format: .currency(code: "INR"))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        }
                    }

                    // Badges row — pin, missed, schedule status
                    let hasAnyBadge = loan.isPinned || (loan.missedEMIs ?? 0) > 0 || loan.scheduleStatus != nil
                    if hasAnyBadge {
                        HStack(spacing: 6) {
                            if loan.isPinned {
                                Label("Pinned", systemImage: "pin.fill")
                                    .labelStyle(.tight)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                            if let missed = loan.missedEMIs, missed > 0 {
                                Label("\(missed) missed", systemImage: "exclamationmark.circle.fill")
                                    .labelStyle(.tight)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.15))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                            }
                            if let status = loan.scheduleStatus {
                                let isAhead = status.contains("ahead")
                                let isBehind = status.contains("behind")
                                let sym = isAhead ? "arrow.up.right" : isBehind ? "arrow.down.right" : "checkmark"
                                let col: Color = isAhead ? .green : isBehind ? .red : .secondary
                                Label(status, systemImage: sym)
                                    .labelStyle(.tight)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(col.opacity(0.15))
                                    .foregroundStyle(col)
                                    .clipShape(Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    ProgressView(value: loan.progressFraction)
                        .tint(.accentColor)
                    HStack {
                        Text("\(Int(loan.progressFraction * 100))% paid")
                        Spacer()
                        if loan.tenureMonths > 0 {
                            Text("\(loan.totalMonthsPaid) of \(loan.tenureMonths) mo")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            // MARK: Balance
            Section("Balance") {
                summaryRow("Original", loan.principal)
                summaryRow("Principal Paid", loan.totalPrincipalPaid)
                summaryRow(loan.isInterestPaidEstimated ? "Interest Paid (est.)" : "Interest Paid",
                           loan.totalInterestPaid)
            }

            // MARK: EMI
            Section("EMI") {
                summaryRow("Amount", loan.monthlyPayment)
                HStack {
                    Text("Due On")
                    Spacer()
                    Text(loan.emiDayDisplay).foregroundStyle(.secondary)
                }
                if let next = loan.nextEMIDate, let days = loan.daysUntilNextEMI {
                    HStack {
                        Text("Next EMI")
                        Spacer()
                        Text(next, format: .dateTime.day().month(.abbreviated).year())
                            .foregroundStyle(.secondary)
                        Text(days == 0 ? "(today)" : days == 1 ? "(tomorrow)" : "(in \(days)d)")
                            .font(.caption)
                            .foregroundStyle(days <= 3 ? .orange : .secondary)
                    }
                }
            }

            // MARK: Terms
            Section("Terms") {
                HStack {
                    Text("Rate")
                    Spacer()
                    Text(loan.annualInterestRate, format: .percent.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Tenure")
                    Spacer()
                    Text(loan.tenureDisplay).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Start Date")
                    Spacer()
                    Text(loan.startDate, format: .dateTime.day().month(.abbreviated).year())
                        .foregroundStyle(.secondary)
                }
                if let scheduled = loan.scheduledEndDate {
                    HStack {
                        Text("Scheduled End")
                        Spacer()
                        Text(scheduled, format: .dateTime.month(.abbreviated).year())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: Progress
            Section("Progress") {
                if loan.tenureMonths > 0 {
                    HStack {
                        Text("Months Paid")
                        Spacer()
                        Text("\(loan.totalMonthsPaid) of \(loan.tenureMonths)")
                            .foregroundStyle(.secondary)
                    }
                }
                if loan.derivedElapsedMonths > 0 && loan.currentOutstanding == 0 {
                    HStack {
                        Text("EMIs Before Tracking")
                        Spacer()
                        Text("\(loan.derivedElapsedMonths)")
                            .foregroundStyle(.secondary)
                    }
                    if loan.paidBeforeTracking > 0 {
                        HStack {
                            Text("Paid in That Period")
                            Spacer()
                            Text(loan.paidBeforeTracking, format: .currency(code: "INR"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("Payments Tracked")
                    Spacer()
                    Text("\(loan.payments.count)")
                        .foregroundStyle(.secondary)
                }
                if let close = loan.estimatedCloseDate {
                    HStack {
                        Text("Est. Close")
                        Spacer()
                        Text(close, format: .dateTime.month(.abbreviated).year())
                            .foregroundStyle(.secondary)
                    }
                }
                if let status = loan.scheduleStatus {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(status)
                            .foregroundStyle(status.contains("ahead") ? .green :
                                             status.contains("behind") ? .red : .secondary)
                    }
                }
            }

            // MARK: Playground
            if loan.remainingBalance > 0.01 {
                Section {
                    PrepaymentPlayground(loan: loan)
                } header: {
                    Text("What If?")
                } footer: {
                    Text("Drag the sliders to see how prepaying extra reduces your tenure and interest.")
                }
                .id("playground")
            }

            // MARK: Payments
            Section("Payments (\(loan.payments.count))") {
                if loan.payments.isEmpty {
                    Text("No payments yet").foregroundStyle(.secondary)
                } else {
                    ForEach(loan.payments.sorted { $0.date > $1.date }) { p in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.amount, format: .currency(code: "INR"))
                                    .font(.headline)
                                if let note = p.note, !note.isEmpty {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(p.date, format: .dateTime.day().month(.abbreviated))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deletePayments)
                }
            }
        }
        .task(id: autoScrollToPlayground) {
            // Auto-scroll to playground when navigated in from a nudge.
            // Single animated scroll after enough delay for List layout to settle
            // on first appearance — a previous "snap-then-animate" double-attempt
            // killed the animation because the snap already put us at the target.
            guard autoScrollToPlayground else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                proxy.scrollTo("playground", anchor: .top)
            }
        }
        } // end ScrollViewReader
        .navigationTitle(loan.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit Loan", systemImage: "pencil") {
                        showingEditLoan = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showingAddPayment = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddPayment) {
            AddPaymentView(loans: [loan], preselected: loan)
        }
        .sheet(isPresented: $showingEditLoan) {
            LoanFormView(loan: loan)
        }
    }

    private func summaryRow(_ label: String, _ value: Double, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value, format: .currency(code: "INR"))
                .fontWeight(emphasized ? .bold : .regular)
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
    }

    private func deletePayments(at offsets: IndexSet) {
        let sorted = loan.payments.sorted { $0.date > $1.date }
        for index in offsets { context.delete(sorted[index]) }
        try? context.save()
        refreshAppState()
    }
}

// MARK: - Prepayment Playground

struct PrepaymentPlayground: View {
    let loan: Loan
    @State private var lumpSum: Double = 0
    @State private var extraMonthly: Double = 0
    /// Computed once on first appearance — baseline never changes during the
    /// playground session, so caching avoids recomputing it on every slider tick.
    @State private var baselineTrajectory: [Double] = []

    private var baseline: PrepaymentProjection? {
        loan.projection(extraLumpSum: 0, extraMonthly: 0)
    }

    private var scenario: PrepaymentProjection? {
        loan.projection(extraLumpSum: lumpSum, extraMonthly: extraMonthly)
    }

    private var hasPrepayment: Bool {
        lumpSum > 0 || extraMonthly > 0
    }

    private var maxLumpSum: Double {
        max(10_000, ceil(loan.remainingBalance / 10_000) * 10_000)
    }

    private var maxExtraMonthly: Double {
        max(1_000, ceil(loan.monthlyPayment * 2 / 500) * 500)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("One-time prepayment")
                Spacer()
                Text(lumpSum, format: .currency(code: "INR").precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $lumpSum, in: 0...maxLumpSum, step: 1_000)
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Extra monthly")
                Spacer()
                Text(extraMonthly, format: .currency(code: "INR").precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $extraMonthly, in: 0...maxExtraMonthly, step: 100)
            // Clarify: the "extra" gets ADDED to the regular EMI. Show the
            // resulting total so the user doesn't have to do the math.
            if extraMonthly > 0 {
                Text("EMI becomes \((loan.monthlyPayment + extraMonthly), format: .currency(code: "INR").precision(.fractionLength(0)))/mo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("On top of your regular ₹\(Int(loan.monthlyPayment)) EMI")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        // Balance decline chart — live updates on every slider tick.
        // Baseline is cached; scenario recomputes per frame.
        BalanceTrajectoryChart(
            baseline: baselineTrajectory,
            scenario: hasPrepayment ? loan.balanceTrajectory(extraLumpSum: lumpSum, extraMonthly: extraMonthly) : nil
        )
        .onAppear {
            if baselineTrajectory.isEmpty {
                baselineTrajectory = loan.balanceTrajectory()
            }
        }

        if hasPrepayment, let base = baseline, let scen = scenario {
            resultView(baseline: base, scenario: scen)
            Button(role: .destructive) {
                withAnimation {
                    lumpSum = 0
                    extraMonthly = 0
                }
            } label: {
                HStack {
                    Spacer()
                    Text("Reset")
                    Spacer()
                }
            }
        } else if hasPrepayment {
            Text("Couldn't compute projection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultView(baseline: PrepaymentProjection, scenario: PrepaymentProjection) -> some View {
        let monthsSaved = max(0, Int(ceil(baseline.monthsRemaining - scenario.monthsRemaining)))
        let interestSaved = max(0, baseline.interestRemaining - scenario.interestRemaining)

        VStack(spacing: 14) {
            if scenario.isPaidOff {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text("Loan paid off today!")
                        .font(.headline)
                    Spacer()
                }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New close date")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(scenario.closeDate, format: .dateTime.month(.abbreviated).year())
                            .font(.subheadline.bold())
                    }
                    Spacer()
                    if monthsSaved > 0 {
                        Text("\(monthsSaved) mo sooner")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
            }

            Divider()

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interest saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(interestSaved, format: .currency(code: "INR").precision(.fractionLength(0)))
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Balance after")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(max(0, loan.remainingBalance - lumpSum),
                         format: .currency(code: "INR").precision(.fractionLength(0)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current plan")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(baseline.totalCashRemaining,
                         format: .currency(code: "INR").precision(.fractionLength(0)))
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("With prepayment")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(scenario.totalCashRemaining,
                         format: .currency(code: "INR").precision(.fractionLength(0)))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Balance Trajectory Chart

/// Two-line chart inside the playground showing how the outstanding balance
/// declines over time. Baseline is always drawn (the user's current plan).
/// The scenario line draws on top in accent color when prepayment is active,
/// so users can see how prepayment changes the shape of the decline.
struct BalanceTrajectoryChart: View {
    let baseline: [Double]
    /// nil when there's no prepayment — chart shows just the baseline curve.
    let scenario: [Double]?

    /// Max chart points per curve. Visually indistinguishable from rendering
    /// every monthly point, but ~5x less work for SwiftUI's diff engine when
    /// the slider is being dragged in real time.
    private let maxChartPoints = 50

    /// Downsample to at most `maxChartPoints`, preserving the original month
    /// index (so x-axis labels stay accurate) and always including the final
    /// point (so the endpoint marker lands on the true close month).
    private func downsample(_ trajectory: [Double]) -> [(month: Int, balance: Double)] {
        guard !trajectory.isEmpty else { return [] }
        if trajectory.count <= maxChartPoints {
            return trajectory.enumerated().map { (month: $0.offset, balance: $0.element) }
        }
        let step = Double(trajectory.count - 1) / Double(maxChartPoints - 1)
        return (0..<maxChartPoints).map { i in
            let idx = min(Int((Double(i) * step).rounded()), trajectory.count - 1)
            return (month: idx, balance: trajectory[idx])
        }
    }

    private var baselinePoints: [(month: Int, balance: Double)] {
        downsample(baseline)
    }

    private var scenarioPoints: [(month: Int, balance: Double)]? {
        scenario.map { downsample($0) }
    }

    /// Compact INR formatting for chart y-axis labels (₹4L, ₹50K, etc.).
    private func compact(_ v: Double) -> String {
        if v >= 100_000 { return String(format: "₹%.1fL", v / 100_000) }
        if v >= 1_000   { return "₹\(Int(v / 1_000))K" }
        return "₹\(Int(v))"
    }

    /// Y-axis upper bound — slightly above the starting balance so the curve
    /// has breathing room at the top.
    private var yMax: Double {
        let firstBaseline = baseline.first ?? 0
        return firstBaseline * 1.05
    }

    /// X-axis range derived from the longer of the two trajectories.
    private var xMax: Int {
        max(baseline.count, scenario?.count ?? 0) - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                legendDot(color: .secondary, label: "Current plan")
                if scenario != nil {
                    legendDot(color: .accentColor, label: "With prepayment")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Chart {
                // Baseline curve — dashed line only, no fill (keeps scenario as hero)
                ForEach(baselinePoints, id: \.month) { point in
                    LineMark(
                        x: .value("Month", point.month),
                        y: .value("Balance", point.balance),
                        series: .value("Plan", "Current")
                    )
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .interpolationMethod(.catmullRom)
                }

                // Subtle endpoint dot for baseline
                if let lastBase = baselinePoints.last {
                    PointMark(
                        x: .value("Month", lastBase.month),
                        y: .value("Balance", lastBase.balance)
                    )
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .symbolSize(30)
                }

                // Scenario curve — gradient area + bold line + endpoint marker
                if let scenarioPoints {
                    ForEach(scenarioPoints, id: \.month) { point in
                        AreaMark(
                            x: .value("Month", point.month),
                            y: .value("Balance", point.balance),
                            series: .value("Plan", "With Prepayment")
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.42),
                                    Color.accentColor.opacity(0.04)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }

                    ForEach(scenarioPoints, id: \.month) { point in
                        LineMark(
                            x: .value("Month", point.month),
                            y: .value("Balance", point.balance),
                            series: .value("Plan", "With Prepayment")
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                    }

                    // Hero endpoint marker with date pill that stays within chart bounds
                    if let last = scenarioPoints.last {
                        PointMark(
                            x: .value("Month", last.month),
                            y: .value("Balance", last.balance)
                        )
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(90)
                        .annotation(
                            position: .top,
                            alignment: .center,
                            spacing: 8,
                            overflowResolution: .init(x: .fit(to: .chart),
                                                      y: .disabled)
                        ) {
                            if let closeDate = Calendar.current.date(byAdding: .month, value: last.month, to: .now) {
                                Text(closeDate, format: .dateTime.month(.abbreviated).year())
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let m = value.as(Int.self) {
                            Text(m == 0 ? "Now" : "\(m)mo")
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(compact(v))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...yMax)
            .chartXScale(domain: 0...max(1, xMax))
            .frame(height: 140)
        }
        .padding(.vertical, 4)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }
}

// MARK: - Loan Form (Create or Edit)

enum TenureUnit: String, CaseIterable {
    case months, years
}

struct LoanFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the form edits this loan in place. When nil, it creates a new one.
    let existingLoan: Loan?

    @State private var name: String
    @State private var principal: Double
    @State private var ratePercent: Double
    @State private var emi: Double
    @State private var startDate: Date
    @State private var tenureValue: Int
    @State private var tenureUnit: TenureUnit
    @State private var paidBeforeTracking: Double
    @State private var currentOutstanding: Double
    @State private var elapsedMonths: Double
    @State private var selectedIcon: LoanIcon
    /// First EMI date — auto-populated to startDate + 1 month, but the user can
    /// change it freely (for loans with a Pre-EMI period before full EMIs begin).
    /// The day component of this date IS the EMI day; no separate stepper needed.
    @State private var firstEMIDate: Date
    /// Tracks whether the user has manually touched the first EMI date.
    /// When false, startDate changes auto-update firstEMIDate; once edited, it stays put.
    @State private var firstEMIUserEdited: Bool

    init(loan: Loan? = nil) {
        self.existingLoan = loan
        if let loan = loan {
            _name = State(initialValue: loan.name)
            _principal = State(initialValue: loan.principal)
            _ratePercent = State(initialValue: loan.annualInterestRate * 100)
            _emi = State(initialValue: loan.monthlyPayment)
            _startDate = State(initialValue: loan.startDate)
            let (tv, tu) = Self.splitTenure(loan.tenureMonths)
            _tenureValue = State(initialValue: tv)
            _tenureUnit = State(initialValue: tu)
            _paidBeforeTracking = State(initialValue: loan.paidBeforeTracking)
            _currentOutstanding = State(initialValue: loan.currentOutstanding)
            _elapsedMonths = State(initialValue: loan.elapsedMonths)
            _selectedIcon = State(initialValue: LoanIcon.resolve(loan.iconKey))
            _firstEMIDate = State(initialValue: loan.firstEMIDate ?? loan.effectiveFirstEMIDate)
            _firstEMIUserEdited = State(initialValue: true)
        } else {
            _name = State(initialValue: "")
            _principal = State(initialValue: 0)
            _ratePercent = State(initialValue: 8.5)
            _emi = State(initialValue: 0)
            _startDate = State(initialValue: .now)
            _tenureValue = State(initialValue: 20)
            _tenureUnit = State(initialValue: .years)
            _paidBeforeTracking = State(initialValue: 0)
            _currentOutstanding = State(initialValue: 0)
            _elapsedMonths = State(initialValue: 0)
            _selectedIcon = State(initialValue: .generic)
            _firstEMIDate = State(initialValue: Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now)
            _firstEMIUserEdited = State(initialValue: false)
        }
    }

    private var isEditing: Bool { existingLoan != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Icon picker — a horizontal scrolling row of selectable icons.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(LoanIcon.allCases) { icon in
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    Image(systemName: icon.systemImage)
                                        .font(.title2)
                                        .frame(width: 44, height: 44)
                                        .background(selectedIcon == icon ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.10))
                                        .foregroundStyle(selectedIcon == icon ? Color.accentColor : .secondary)
                                        .clipShape(Circle())
                                        .overlay(
                                            Circle().stroke(selectedIcon == icon ? Color.accentColor : .clear, lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

                    TextField("Name (e.g. Home Loan)", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    numberRow("Principal", value: $principal)
                    numberRow("Interest Rate %", value: $ratePercent)
                    numberRow("Monthly EMI", value: $emi)
                    DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                        .onChange(of: startDate) { _, newDate in
                            // Auto-advance first EMI to one month after the new start date,
                            // unless the user has explicitly edited it.
                            if !firstEMIUserEdited {
                                firstEMIDate = Calendar.current.date(byAdding: .month, value: 1, to: newDate) ?? newDate
                            }
                            let comps = Calendar.current.dateComponents([.month], from: newDate, to: .now)
                            let months = max(0, comps.month ?? 0)
                            elapsedMonths = Double(min(months, tenureInMonths))
                        }

                    DatePicker("First EMI Date",
                               selection: $firstEMIDate,
                               in: startDate...,
                               displayedComponents: .date)
                        .onChange(of: firstEMIDate) { _, _ in
                            firstEMIUserEdited = true
                        }

                    HStack {
                        Text("Tenure")
                        Spacer()
                        TextField("0", value: $tenureValue, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 60)
                        Picker("", selection: $tenureUnit) {
                            Text("Months").tag(TenureUnit.months)
                            Text("Years").tag(TenureUnit.years)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                } header: {
                    Text("Loan")
                } footer: {
                    Text("First EMI auto-populates to one month after Start Date. Change it if your loan has a Pre-EMI period before full EMIs begin — log any Pre-EMI interest under \"Total Paid So Far\".")
                }

                Section {
                    numberRow("EMIs Paid", value: $elapsedMonths)
                    numberRow("Total Paid So Far", value: $paidBeforeTracking)
                } header: {
                    Text("Already in Progress?")
                } footer: {
                    Text("EMIs Paid is auto-detected from your start date — override if your loan deducts an advance EMI at disbursement, has a moratorium, or any other unusual timing. Total Paid is optional — fill in only if you've been paying more than the scheduled EMI.")
                }

                Section {
                    numberRow("Current Outstanding", value: $currentOutstanding)
                } header: {
                    Text("Or, Skip the Math")
                } footer: {
                    Text("If you already know your current outstanding from your bank app or statement, enter it here. This overrides the calculation above and becomes the source of truth.")
                }
            }
            .navigationTitle(isEditing ? "Edit Loan" : "New Loan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
        }
    }

    /// Uses the shared FormattedAmountField so the field shows empty when
    /// the underlying value is 0, and inserts commas as the user types.
    private func numberRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            FormattedAmountField(value: value)
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && principal > 0 && emi > 0 && ratePercent >= 0 && tenureValue > 0
        && paidBeforeTracking >= 0
        && currentOutstanding >= 0 && currentOutstanding <= principal
    }

    private var tenureInMonths: Int {
        tenureUnit == .years ? tenureValue * 12 : tenureValue
    }

    /// Default first EMI date — one month after startDate on the EMI day.
    /// Used as the fallback when the user hasn't enabled "Custom first EMI" override.
    private static func splitTenure(_ months: Int) -> (Int, TenureUnit) {
        guard months > 0 else { return (20, .years) }
        if months % 12 == 0 {
            return (months / 12, .years)
        }
        return (months, .months)
    }

    private func save() {
        // EMI day is derived from the first-EMI date — the model still keeps
        // emiDay as a separate field, but the user only picks the date.
        let derivedEMIDay = Calendar.current.component(.day, from: firstEMIDate)

        if let existing = existingLoan {
            existing.name = name
            existing.principal = principal
            existing.annualInterestRate = ratePercent / 100.0
            existing.monthlyPayment = emi
            existing.elapsedMonths = elapsedMonths
            existing.paidBeforeTracking = paidBeforeTracking
            existing.currentOutstanding = currentOutstanding
            existing.startDate = startDate
            existing.tenureMonths = tenureInMonths
            existing.emiDay = derivedEMIDay
            existing.firstEMIDate = firstEMIDate
            existing.iconKey = selectedIcon.rawValue
        } else {
            let loan = Loan(
                name: name,
                principal: principal,
                annualInterestRate: ratePercent / 100.0,
                monthlyPayment: emi,
                elapsedMonths: elapsedMonths,
                paidBeforeTracking: paidBeforeTracking,
                currentOutstanding: currentOutstanding,
                startDate: startDate,
                tenureMonths: tenureInMonths,
                emiDay: derivedEMIDay,
                firstEMIDate: firstEMIDate,
                iconKey: selectedIcon.rawValue
            )
            context.insert(loan)
        }
        try? context.save()
        refreshAppState()
        dismiss()
    }
}

// MARK: - Add Payment

struct AddPaymentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let loans: [Loan]
    var preselected: Loan? = nil
    /// When > 0, pre-fills the amount field — used by the "Pay EMI" quick action.
    var defaultAmount: Double = 0

    @State private var selectedLoan: Loan?
    @State private var amount: Double = 0
    @State private var date: Date = .now
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Loan") {
                    Picker("Loan", selection: $selectedLoan) {
                        Text("Select…").tag(Loan?.none)
                        ForEach(loans) { loan in
                            Text(loan.name).tag(Loan?.some(loan))
                        }
                    }
                }
                Section("Payment") {
                    HStack {
                        Text("Amount")
                        Spacer()
                        FormattedAmountField(value: $amount)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                }
            }
            .navigationTitle("Add Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
            .onAppear {
                if selectedLoan == nil { selectedLoan = preselected ?? loans.first }
                if amount == 0, defaultAmount > 0 { amount = defaultAmount }
            }
        }
    }

    private var isValid: Bool { selectedLoan != nil && amount > 0 }

    private func save() {
        guard let loan = selectedLoan else { return }
        let payment = Payment(amount: amount, date: date, note: note.isEmpty ? nil : note)
        payment.loan = loan
        context.insert(payment)
        try? context.save()
        refreshAppState()
        dismiss()
    }
}

// MARK: - Formatted Amount Field

/// Text field for monetary/numeric input.
/// - Shows empty placeholder when the bound value is 0
/// - Formats with Indian-style grouping (1,25,000) live as the user types
/// - Accepts decimals via the decimal-pad keyboard (e.g. 8.5 for interest rate)
struct FormattedAmountField: View {
    @Binding var value: Double
    @State private var text: String = ""

    /// Explicit Indian grouping: groups of 3 then 2 thereafter.
    /// (Locale alone doesn't always activate this — set sizes explicitly.)
    private static let formatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.groupingSize = 3
        nf.secondaryGroupingSize = 2
        nf.usesGroupingSeparator = true
        nf.groupingSeparator = ","
        nf.maximumFractionDigits = 2
        return nf
    }()

    var body: some View {
        TextField("", text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .onAppear {
                // Initial display from the bound value
                text = formatted(value)
            }
            .onChange(of: text) { _, newValue in
                handleTextChange(newValue)
            }
            .onChange(of: value) { _, newValue in
                // External value change (e.g. from a reset or programmatic update)
                let formattedExternal = formatted(newValue)
                if formattedExternal != text {
                    text = formattedExternal
                }
            }
    }

    /// Convert a Double to its display string ("" for zero, formatted otherwise).
    private func formatted(_ v: Double) -> String {
        v == 0 ? "" : (Self.formatter.string(from: NSNumber(value: v)) ?? "")
    }

    private func handleTextChange(_ input: String) {
        let cleaned = input.replacingOccurrences(of: ",", with: "")

        // Empty field → value 0
        guard !cleaned.isEmpty else {
            value = 0
            return
        }

        // Parse as Double (decimal-pad allows "1234" or "12.5")
        guard let parsed = Double(cleaned) else { return }
        value = parsed

        if cleaned.contains(".") {
            // Has a decimal: format only the whole-number part with commas,
            // preserve everything after the dot exactly as the user typed it
            // (so typing "12.", "12.5", "12.50" all stay legible without
            // stripping trailing zeros or losing the dot).
            let parts = cleaned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let whole = Double(parts[0]) else { return }
            let formattedWhole = Self.formatter.string(from: NSNumber(value: whole)) ?? parts[0]
            let display = "\(formattedWhole).\(parts[1])"
            if display != input { text = display }
        } else {
            // Whole number — apply Indian grouping
            let display = Self.formatter.string(from: NSNumber(value: parsed)) ?? cleaned
            if display != input { text = display }
        }
    }
}

// MARK: - Export Backup Sheet

struct ExportBackupSheet: View {
    let loans: [Loan]
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var preparedData: Data?
    @State private var showingFileExporter = false
    @State private var errorMessage: String?

    private var passphraseValid: Bool {
        passphrase.count >= 4 && passphrase == confirmPassphrase
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your backup file is encrypted with this passphrase. You'll need the exact same passphrase to restore it later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Passphrase") {
                    SecureField("At least 4 characters", text: $passphrase)
                    SecureField("Confirm passphrase", text: $confirmPassphrase)
                    if !confirmPassphrase.isEmpty && passphrase != confirmPassphrase {
                        Text("Passphrases don't match")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Label("Write down or save your passphrase somewhere safe. Without it, the backup cannot be opened — not even by you.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Export Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        prepareAndExport()
                    }
                    .disabled(!passphraseValid)
                }
            }
            .fileExporter(
                isPresented: $showingFileExporter,
                document: EncryptedBackupDocument(data: preparedData ?? Data()),
                contentType: .json,
                defaultFilename: backupFilename()
            ) { result in
                switch result {
                case .success: dismiss()
                case .failure(let err): errorMessage = err.localizedDescription
                }
            }
        }
    }

    private func backupFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "loan-tracker-\(f.string(from: .now))"
    }

    private func prepareAndExport() {
        do {
            preparedData = try BackupManager.exportData(loans: loans, passphrase: passphrase)
            errorMessage = nil
            showingFileExporter = true
        } catch {
            errorMessage = "Could not prepare backup: \(error.localizedDescription)"
        }
    }
}

// MARK: - Import Backup Sheet

struct ImportBackupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showingFilePicker = true
    @State private var fileData: Data?
    @State private var fileName: String?
    @State private var passphrase = ""
    @State private var previewedLoans: [LoanBackupDTO] = []
    @State private var stage: Stage = .pickingFile
    @State private var errorMessage: String?

    enum Stage {
        case pickingFile, enteringPassphrase, confirmingReplace
    }

    var body: some View {
        NavigationStack {
            Form {
                switch stage {
                case .pickingFile:
                    Section {
                        Text("Select a `.json` backup file you previously exported. It can be from Files, iCloud Drive, Google Drive, or any other location.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button {
                            showingFilePicker = true
                        } label: {
                            Label("Choose Backup File", systemImage: "doc.badge.arrow.up")
                        }
                    }
                case .enteringPassphrase:
                    Section {
                        if let name = fileName {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.secondary)
                                Text(name)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    Section("Passphrase") {
                        SecureField("Enter passphrase used during export", text: $passphrase)
                    }
                case .confirmingReplace:
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ready to restore \(previewedLoans.count) loan\(previewedLoans.count == 1 ? "" : "s")")
                                .font(.headline)
                            Text("This will **replace all current data** in the app with the contents of the backup. This cannot be undone.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Will restore") {
                        ForEach(previewedLoans, id: \.id) { loan in
                            HStack {
                                Text(loan.name)
                                Spacer()
                                Text("\(loan.payments.count) payment\(loan.payments.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    switch stage {
                    case .pickingFile:
                        EmptyView()
                    case .enteringPassphrase:
                        Button("Decrypt") { tryDecrypt() }
                            .disabled(passphrase.isEmpty)
                    case .confirmingReplace:
                        Button("Restore") { performRestore() }
                            .foregroundStyle(.red)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    do {
                        fileData = try Data(contentsOf: url)
                        fileName = url.lastPathComponent
                        stage = .enteringPassphrase
                        errorMessage = nil
                    } catch {
                        errorMessage = "Could not read file: \(error.localizedDescription)"
                    }
                case .failure(let err):
                    if (err as NSError).code != NSUserCancelledError {
                        errorMessage = err.localizedDescription
                    }
                    if fileData == nil { dismiss() }
                }
            }
        }
    }

    private func tryDecrypt() {
        guard let fileData else { return }
        do {
            let loans = try BackupManager.previewImport(fileData: fileData, passphrase: passphrase)
            previewedLoans = loans
            stage = .confirmingReplace
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performRestore() {
        do {
            try BackupManager.restore(loans: previewedLoans, context: context)
            refreshAppState()
            dismiss()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Nudge Card

/// A contextual suggestion card shown on the home screen. Driven by NudgeEngine.
/// Tappable (to drill into the relevant loan) and dismissable (with cooldown).
struct NudgeCard: View {
    let nudge: Nudge
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Tinted icon column
                Image(systemName: nudge.icon)
                    .font(.title2)
                    .foregroundStyle(nudge.tint.color)
                    .frame(width: 36, height: 36)
                    .background(nudge.tint.color.opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(nudge.title.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(nudge.tint.color)
                            .tracking(0.5)
                        Spacer(minLength: 0)
                    }

                    Text(nudge.message)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let label = nudge.actionLabel {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(nudge.tint.color)
                            .padding(.top, 2)
                    }
                }

                // Dismiss button — separate tap target with own action.
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                // Subtle accent stripe on the left edge — ties the card to the
                // tint without overwhelming. Apple Wallet card-art trick.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(nudge.tint.color.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

// MARK: - Label Style

/// Custom Label style with tight icon-to-text spacing (2pt by default).
/// SwiftUI's default Label gives a fair amount of room between icon and text,
/// which looks unbalanced inside small pill badges. This brings them closer.
struct TightLabelStyle: LabelStyle {
    var spacing: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == TightLabelStyle {
    /// Apply via `.labelStyle(.tight)` — 2pt icon-to-text spacing.
    static var tight: TightLabelStyle { TightLabelStyle() }
}

import SwiftUI
import SwiftData
import UserNotifications
import UIKit
import LocalAuthentication

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Loan.createdAt) private var loans: [Loan]

    // Bound to UserDefaults via @AppStorage so changes persist.
    @AppStorage("reminderEnabled")     private var reminderEnabled: Bool = false
    @AppStorage("reminderDaysBefore")  private var reminderDaysBefore: Int = 3
    @AppStorage("reminderHour")        private var reminderHour: Int = 9
    @AppStorage("reminderMinute")      private var reminderMinute: Int = 0
    /// -1 sentinel = secondary alert off. Any value 0...7 = enabled at that days-before.
    /// Using a sentinel rather than Optional since @AppStorage handles Int cleanly.
    @AppStorage("reminderSecondaryDaysBefore") private var reminderSecondaryDaysBefore: Int = -1

    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var showingExportSheet = false
    @State private var showingImportSheet = false
    @State private var showingCSVExport = false
    @State private var showingPermissionAlert = false
    @State private var biometricManager = BiometricLockManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true
    @AppStorage("defaultCurrency") private var defaultCurrency: String = Locale.current.currency?.identifier ?? "USD"

    var body: some View {
        NavigationStack {
            Form {
                notificationsSection
                currencySection
                securitySection
                dataSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingExportSheet) {
                ExportBackupSheet(loans: loans)
            }
            .sheet(isPresented: $showingImportSheet) {
                ImportBackupSheet()
            }
            .sheet(isPresented: $showingCSVExport) {
                CSVExportSheet(loans: loans)
            }
            .alert("Notifications Disabled", isPresented: $showingPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enable notifications for Loan Tracker in iOS Settings to receive EMI reminders.")
            }
            .task {
                authStatus = await NotificationManager.authorizationStatus()
                biometricManager.checkBiometrics()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            Toggle("EMI Reminders", isOn: $reminderEnabled)
                .onChange(of: reminderEnabled) { _, newValue in
                    Task { await handleReminderToggle(enabled: newValue) }
                }

            if reminderEnabled && authStatus == .authorized {
                Picker("First Alert", selection: $reminderDaysBefore) {
                    Text("Same day").tag(0)
                    Text("1 day before").tag(1)
                    Text("3 days before").tag(3)
                    Text("7 days before").tag(7)
                }
                .onChange(of: reminderDaysBefore) { _, _ in
                    refreshNotifications(loans: loans)
                }

                // Optional second alert — useful for "remind me 3 days ahead AND
                // again the day before" combinations.
                Picker("Second Alert", selection: $reminderSecondaryDaysBefore) {
                    Text("Off").tag(-1)
                    Text("Same day").tag(0)
                    Text("1 day before").tag(1)
                    Text("3 days before").tag(3)
                    Text("7 days before").tag(7)
                }
                .onChange(of: reminderSecondaryDaysBefore) { _, newValue in
                    // Write through to ReminderPrefs as Optional Int
                    ReminderPrefs.secondaryDaysBefore = newValue >= 0 ? newValue : nil
                    refreshNotifications(loans: loans)
                }

                DatePicker(
                    "Notify At",
                    selection: reminderTimeBinding,
                    displayedComponents: .hourAndMinute
                )
                .onChange(of: reminderHour) { _, _ in
                    refreshNotifications(loans: loans)
                }
                .onChange(of: reminderMinute) { _, _ in
                    refreshNotifications(loans: loans)
                }

//                Button {
//                    NotificationManager.sendTestNotification()
//                } label: {
//                    Label("Send Test Notification", systemImage: "bell.badge")
//                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            if reminderEnabled && authStatus == .denied {
                Text("Notifications are blocked in iOS Settings. Tap to enable them.")
                    .foregroundStyle(.orange)
                    .onTapGesture { showingPermissionAlert = true }
            } else if reminderEnabled && authStatus == .authorized {
                if reminderSecondaryDaysBefore >= 0 && reminderSecondaryDaysBefore != reminderDaysBefore {
                    Text("You'll be reminded \(daysBeforeDescription(reminderDaysBefore)) and again \(daysBeforeDescription(reminderSecondaryDaysBefore)) each EMI is due, at \(formatHour(reminderHour, minute: reminderMinute)).")
                } else {
                    Text("You'll be reminded \(daysBeforeDescription(reminderDaysBefore)) each EMI is due, at \(formatHour(reminderHour, minute: reminderMinute)).")
                }
            } else {
                Text("Get a heads-up before each EMI is due. Choose how many days in advance and what time of day.")
            }
        }
    }

    @State private var showCurrencyApplied = false

    /// How many existing loans use a different currency than the default.
    private var loansMismatchingCurrency: Int {
        loans.filter { $0.currencyCode != defaultCurrency }.count
    }

    @ViewBuilder
    private var currencySection: some View {
        Section {
            Picker("Default Currency", selection: $defaultCurrency) {
                ForEach(SupportedCurrency.allCases) { currency in
                    Text(currency.label).tag(currency.rawValue)
                }
            }

            if loansMismatchingCurrency > 0 {
                Button {
                    for loan in loans {
                        loan.currencyCode = defaultCurrency
                    }
                    try? context.save()
                    showCurrencyApplied = true
                } label: {
                    Label("Apply to all \(loans.count) loan\(loans.count == 1 ? "" : "s")", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            if showCurrencyApplied {
                Text("Updated all loans to \(defaultCurrency)")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Currency")
        } footer: {
            if loansMismatchingCurrency > 0 {
                Text("\(loansMismatchingCurrency) loan\(loansMismatchingCurrency == 1 ? " uses" : "s use") a different currency. Tap \"Apply to all\" to update them, or change currency individually per loan.")
            } else {
                Text("New loans will default to this currency. You can change it per loan.")
            }
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { biometricManager.isEnabled },
                set: { newValue in
                    biometricManager.isEnabled = newValue
                    if newValue {
                        // Verify biometrics work when enabling
                        Task { await biometricManager.authenticate() }
                    }
                }
            )) {
                Label(biometricManager.biometricName, systemImage: biometricManager.biometricIcon)
            }
            .disabled(biometricManager.biometricType == .none)
        } header: {
            Text("Security")
        } footer: {
            if biometricManager.biometricType == .none {
                Text("No biometric authentication is available on this device.")
            } else {
                Text("Require \(biometricManager.biometricName) to open the app.")
            }
        }
    }

    @ViewBuilder
    private var dataSection: some View {
        Section("Data") {
            Button {
                showingExportSheet = true
            } label: {
                Label("Export Backup…", systemImage: "square.and.arrow.up")
            }
            Button {
                showingImportSheet = true
            } label: {
                Label("Import Backup…", systemImage: "square.and.arrow.down")
            }
            Button {
                showingCSVExport = true
            } label: {
                Label("Export to CSV…", systemImage: "tablecells")
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(versionString)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Loans")
                Spacer()
                Text("\(loans.count)")
                    .foregroundStyle(.secondary)
            }
            Button {
                hasCompletedOnboarding = false
            } label: {
                Label("Replay Onboarding", systemImage: "arrow.counterclockwise")
            }
        }
    }

    // MARK: - Helpers

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func formatHour(_ hour: Int, minute: Int = 0) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let date = Calendar.current.date(from: comps) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// "on the day" / "3 days before" — used in the footer summary.
    private func daysBeforeDescription(_ days: Int) -> String {
        if days == 0 { return "on the day" }
        return "\(days) day\(days == 1 ? "" : "s") before"
    }

    /// Two-way binding that exposes hour+minute as a single Date for DatePicker.
    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents()
                comps.hour = reminderHour
                comps.minute = reminderMinute
                return Calendar.current.date(from: comps) ?? .now
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                reminderHour = c.hour ?? 9
                reminderMinute = c.minute ?? 0
            }
        )
    }

    private func handleReminderToggle(enabled: Bool) async {
        if enabled {
            let granted = await NotificationManager.requestPermission()
            authStatus = await NotificationManager.authorizationStatus()
            if granted {
                refreshNotifications(loans: loans)
            } else {
                // Reflect denial in the UI.
                reminderEnabled = false
                if authStatus == .denied {
                    showingPermissionAlert = true
                }
            }
        } else {
            NotificationManager.cancelAll()
        }
    }
}

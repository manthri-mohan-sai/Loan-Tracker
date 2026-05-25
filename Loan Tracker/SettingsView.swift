import SwiftUI
import SwiftData
import UserNotifications
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
    @State private var showingPermissionAlert = false

    var body: some View {
        NavigationStack {
            Form {
                notificationsSection
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

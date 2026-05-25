import Foundation
import UserNotifications

// MARK: - Plain-data target for scheduling

/// Simple struct passed to NotificationManager so we don't pass SwiftData @Model
/// objects across async boundaries.
struct ReminderTarget {
    let id: UUID
    let name: String
    let monthlyPayment: Double
    let remainingBalance: Double
    let nextEMIDate: Date?
    let emiDay: Int
}

// MARK: - Preferences (UserDefaults-backed; readable by sync code)

enum ReminderPrefs {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.bool(forKey: "reminderEnabled") }
        set { defaults.set(newValue, forKey: "reminderEnabled") }
    }

    /// 0 = same-day, 1/3/7 = N days before. Default 3.
    static var daysBefore: Int {
        get {
            if defaults.object(forKey: "reminderDaysBefore") == nil { return 3 }
            return defaults.integer(forKey: "reminderDaysBefore")
        }
        set { defaults.set(newValue, forKey: "reminderDaysBefore") }
    }

    /// Hour of day to fire (0–23). Default 9 (9 AM).
    static var hour: Int {
        get {
            if defaults.object(forKey: "reminderHour") == nil { return 9 }
            return defaults.integer(forKey: "reminderHour")
        }
        set { defaults.set(newValue, forKey: "reminderHour") }
    }

    /// Minute of the hour to fire (0–59). Default 0.
    static var minute: Int {
        get { defaults.integer(forKey: "reminderMinute") }
        set { defaults.set(newValue, forKey: "reminderMinute") }
    }

    /// Optional second alert. When non-nil, schedules an additional reminder
    /// at N days before each EMI (in addition to the primary). nil = disabled.
    /// Typical use: primary 3 days before, secondary 0 (same-day) for last-chance.
    static var secondaryDaysBefore: Int? {
        get {
            guard defaults.object(forKey: "reminderSecondaryDaysBefore") != nil else { return nil }
            let stored = defaults.integer(forKey: "reminderSecondaryDaysBefore")
            return stored >= 0 ? stored : nil
        }
        set {
            if let v = newValue {
                defaults.set(v, forKey: "reminderSecondaryDaysBefore")
            } else {
                defaults.removeObject(forKey: "reminderSecondaryDaysBefore")
            }
        }
    }
}

// MARK: - Manager

enum NotificationManager {

    /// Request alert + sound permission. Returns true if granted.
    @discardableResult
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Fire a notification ~3 seconds from now. Useful for verifying that permission,
    /// foreground display, and Do Not Disturb settings are all working.
    static func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Test Reminder"
        content.body = "If you see this, EMI reminders are working."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Cancel everything and re-schedule reminders for the given loans based on
    /// the current preferences. Safe to call repeatedly; it's idempotent.
    static func rescheduleAll(targets: [ReminderTarget]) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        guard ReminderPrefs.enabled else { return }
        guard await authorizationStatus() == .authorized else { return }

        let cal = Calendar.current
        let now = Date()
        let primaryDays = ReminderPrefs.daysBefore
        let secondaryDays = ReminderPrefs.secondaryDaysBefore
        let hour = ReminderPrefs.hour
        let minute = ReminderPrefs.minute

        // Schedule the next 3 EMIs for each active loan.
        for loan in targets where loan.remainingBalance > 0.01 {
            for monthOffset in 0..<3 {
                guard let emiDate = projectedEMIDate(for: loan, monthOffset: monthOffset),
                      emiDate > now else { continue }

                // Primary reminder
                await schedule(
                    daysBefore: primaryDays,
                    suffix: "primary",
                    loan: loan,
                    emiDate: emiDate,
                    hour: hour,
                    minute: minute,
                    cal: cal,
                    now: now,
                    center: center
                )

                // Optional secondary reminder — only if user enabled it AND it's
                // not redundant with the primary (different daysBefore value).
                if let secondaryDays, secondaryDays != primaryDays {
                    await schedule(
                        daysBefore: secondaryDays,
                        suffix: "secondary",
                        loan: loan,
                        emiDate: emiDate,
                        hour: hour,
                        minute: minute,
                        cal: cal,
                        now: now,
                        center: center
                    )
                }
            }
        }
    }

    /// Schedules a single reminder. Pulled out so the primary and secondary
    /// alerts can share the same code path.
    private static func schedule(
        daysBefore: Int,
        suffix: String,
        loan: ReminderTarget,
        emiDate: Date,
        hour: Int,
        minute: Int,
        cal: Calendar,
        now: Date,
        center: UNUserNotificationCenter
    ) async {
        guard var triggerDate = cal.date(byAdding: .day, value: -daysBefore, to: emiDate)
        else { return }
        triggerDate = setTime(hour: hour, minute: minute, on: triggerDate, calendar: cal)
        guard triggerDate > now else { return }

        let content = UNMutableNotificationContent()
        content.title = makeTitle(daysBefore: daysBefore)
        content.body = makeBody(loan: loan, daysBefore: daysBefore)
        content.sound = .default
        content.threadIdentifier = loan.id.uuidString

        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let identifier = "\(loan.id.uuidString)-\(Int(emiDate.timeIntervalSince1970))-\(suffix)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    // MARK: - Private helpers

    /// Compute an EMI date N months out from the loan's nextEMIDate.
    /// We use nextEMIDate as the anchor (which itself accounts for payment status this month),
    /// then add months. The day-of-month is clamped per calendar (Feb 30 → Feb 28/29).
    private static func projectedEMIDate(for loan: ReminderTarget, monthOffset: Int) -> Date? {
        guard let anchor = loan.nextEMIDate else { return nil }
        if monthOffset == 0 { return anchor }
        let cal = Calendar.current
        guard let target = cal.date(byAdding: .month, value: monthOffset, to: anchor) else { return nil }
        // Clamp to actual valid day-of-month for the target month.
        var comps = cal.dateComponents([.year, .month], from: target)
        guard let firstOfMonth = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth) else { return target }
        comps.day = min(loan.emiDay, range.upperBound - 1)
        return cal.date(from: comps) ?? target
    }

    private static func setTime(hour: Int, minute: Int, on date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps) ?? date
    }

    private static func makeTitle(daysBefore: Int) -> String {
        switch daysBefore {
        case 0:  return "EMI Due Today"
        case 1:  return "EMI Due Tomorrow"
        default: return "EMI Coming Up"
        }
    }

    private static func makeBody(loan: ReminderTarget, daysBefore: Int) -> String {
        let amount = loan.monthlyPayment.formatted(.currency(code: "INR").precision(.fractionLength(0)))
        switch daysBefore {
        case 0:  return "\(loan.name) — \(amount) is due today."
        case 1:  return "\(loan.name) — \(amount) is due tomorrow."
        default: return "\(loan.name) — \(amount) is due in \(daysBefore) days."
        }
    }
}

// MARK: - Refresh helper

/// Mirror of refreshWidget() for notifications. Call after any data mutation.
/// Safe to call when reminders are disabled (becomes a no-op).
func refreshNotifications(loans: [Loan]) {
    let targets = loans.map { loan in
        ReminderTarget(
            id: loan.id,
            name: loan.name,
            monthlyPayment: loan.monthlyPayment,
            remainingBalance: loan.remainingBalance,
            nextEMIDate: loan.nextEMIDate,
            emiDay: loan.emiDay
        )
    }
    Task {
        await NotificationManager.rescheduleAll(targets: targets)
    }
}

// MARK: - Foreground display delegate

/// Without this delegate, iOS suppresses notification banners while the app is
/// in the foreground. Set this as UNUserNotificationCenter.delegate at app launch.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }
}

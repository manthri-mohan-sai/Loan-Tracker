import SwiftUI
import SwiftData
import WidgetKit
import UserNotifications

@main
struct LoanTrackerApp: App {
    /// Must match the App Group identifier in both the app and widget targets.
    static let appGroupID = "group.com.app.simple-loan-tracker"

    init() {
        // Show notification banners even when the app is in the foreground.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        for family in UIFont.familyNames where family.contains("Playfair") {
            print(family, UIFont.fontNames(forFamilyName: family))
        }
    }

    /// Shared SwiftData store so the widget can read the same data the app writes.
    let sharedContainer: ModelContainer = {
        let schema = Schema([Loan.self, Payment.self, RateChange.self, StoredDocument.self])
        let config = ModelConfiguration(
            "LoanTracker",
            schema: schema,
            groupContainer: .identifier(LoanTrackerApp.appGroupID)
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    @State private var deepLinkRoute: DeepLinkRoute?
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                BiometricGate {
                    SplashGate {
                        HomeView(deepLinkRoute: $deepLinkRoute)
                            .onOpenURL { url in
                                let route = DeepLinkRoute(url: url)
                                deepLinkRoute = route
                            }
                    }
                }
            } else {
                OnboardingView(isComplete: $hasCompletedOnboarding)
            }
        }
        .modelContainer(sharedContainer)
        .handlesExternalEvents(matching: ["loantracker"])
    }
}

// MARK: - Deep Linking

enum DeepLinkRoute: Identifiable, Equatable {
    case addPayment
    case addLoan
    case importDocument(URL)

    var id: String {
        switch self {
        case .addPayment: return "addPayment"
        case .addLoan:    return "addLoan"
        case .importDocument: return "importDocument"
        }
    }

    init?(url: URL) {
        // Handle file:// URLs — shared PDFs/images from other apps
        if url.isFileURL {
            self = .importDocument(url)
            return
        }

        guard url.scheme == "loantracker" else {
            print("⚠️ URL scheme mismatch: \(url.scheme ?? "nil")")
            return nil
        }
        // URL.host can be nil for some URL forms; check both host and pathComponents.
        let key = url.host ?? url.pathComponents.dropFirst().first ?? ""
        switch key {
        case "add-payment": self = .addPayment
        case "add-loan":    self = .addLoan
        default:
            print("⚠️ Unknown deep link key: '\(key)' (host=\(url.host ?? "nil"), path=\(url.path))")
            return nil
        }
    }
}

/// Call this after any data mutation so the widget timeline refreshes.
func refreshWidget() {
    WidgetCenter.shared.reloadAllTimelines()
}

/// Refresh both widgets AND scheduled notifications from any data-mutation site.
/// Pulls the current loans from the shared container so callers don't have to.
@MainActor
func refreshAppState() {
    refreshWidget()
    let schema = Schema([Loan.self, Payment.self, RateChange.self, StoredDocument.self])
    let config = ModelConfiguration(
        "LoanTracker",
        schema: schema,
        groupContainer: .identifier(LoanTrackerApp.appGroupID)
    )
    if let container = try? ModelContainer(for: schema, configurations: [config]),
       let loans = try? ModelContext(container).fetch(FetchDescriptor<Loan>()) {
        refreshNotifications(loans: loans)
    }
}

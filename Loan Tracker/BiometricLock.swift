import SwiftUI
import UIKit
import LocalAuthentication

// MARK: - Biometric Lock Manager

@Observable
final class BiometricLockManager {
    private(set) var isUnlocked = false
    private(set) var biometricType: LABiometryType = .none
    /// Guards against overlapping `authenticate()` calls — the scenePhase-driven
    /// trigger and the lock screen's own appear-triggered/manual attempts can
    /// otherwise both invoke LAContext at once and double-prompt Face ID.
    private var isAuthenticating = false

    static let shared = BiometricLockManager()

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "biometricLockEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "biometricLockEnabled") }
    }

    var biometricName: String {
        switch biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometric"
        }
    }

    var biometricIcon: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    /// Check what biometric hardware is available.
    func checkBiometrics() {
        let context = LAContext()
        var error: NSError?
        // Always read biometryType — it reports hardware capability even when
        // biometrics aren't enrolled, so the UI shows "Face ID" / "Touch ID"
        // correctly on supported devices.
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        biometricType = context.biometryType
    }

    /// Authenticate the user. Returns true on success.
    @MainActor
    func authenticate() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Enter Passcode"

        var error: NSError?

        // Try biometrics (Face ID / Touch ID) first
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Unlock Loan Tracker to view your financial data"
                )
                isUnlocked = success
                return success
            } catch {
                // Biometric failed or was cancelled — fall through to passcode
            }
        }

        // Fall back to device passcode
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometric + no passcode — just unlock
            isUnlocked = true
            return true
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Loan Tracker to view your financial data"
            )
            isUnlocked = success
            return success
        } catch {
            return false
        }
    }

    /// Lock the app (e.g., when going to background).
    func lock() {
        isUnlocked = false
    }
}

// MARK: - Lock Screen

struct BiometricLockScreen: View {
    @State private var manager = BiometricLockManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: manager.biometricIcon)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("Loan Tracker is Locked")
                .font(.title2.bold())

            Text("Authenticate to view your financial data")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Task { await manager.authenticate() }
            } label: {
                Label("Unlock with \(manager.biometricName)", systemImage: manager.biometricIcon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task {
            manager.checkBiometrics()
            _ = await manager.authenticate()
        }
    }
}

// MARK: - Lock Gate Modifier

/// Wraps app content with a biometric lock screen when enabled.
struct BiometricGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var manager = BiometricLockManager.shared
    @Environment(\.scenePhase) private var scenePhase

    private var isLocked: Bool {
        manager.isEnabled && !manager.isUnlocked
    }

    var body: some View {
        // `content()` stays mounted at all times — including while locked — so its
        // navigation state (e.g. a pushed LoanDetailView) survives a lock/unlock
        // cycle instead of being torn down and rebuilt from scratch. The lock
        // screen is drawn as an overlay on top rather than swapped in via `if/else`,
        // which also means it covers the app content immediately as backgrounding
        // starts, before the app-switcher can snapshot the underlying screen.
        content()
            .overlay {
                if isLocked {
                    BiometricLockScreen()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    if manager.isEnabled {
                        manager.lock()
                    }
                case .active:
                    if isLocked {
                        Task { await manager.authenticate() }
                    }
                default:
                    break
                }
            }
            .onAppear {
                manager.checkBiometrics()
            }
    }
}

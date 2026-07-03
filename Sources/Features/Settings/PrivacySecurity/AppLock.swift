import SwiftUI
import Security
import CryptoKit
import LocalAuthentication

/// Local app lock (§10.4): a 4–6 digit passcode stored as a salted SHA-256 hash in
/// the Keychain (never server-side), optional Face ID unlock, and an auto-lock
/// window. The lock overlay renders in RootView UNDER any full-screen call cover,
/// so incoming CallKit call UI bypasses the lock (UI-layer only — call plumbing is
/// untouched).
@MainActor
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    enum AutoLock: String, CaseIterable, Identifiable {
        case immediately
        case oneMinute
        case fiveMinutes
        case onBackground

        var id: String { rawValue }
        var label: String {
            switch self {
            case .immediately:  return String(localized: "Immediately")
            case .oneMinute:    return String(localized: "After 1 minute")
            case .fiveMinutes:  return String(localized: "After 5 minutes")
            case .onBackground: return String(localized: "When app goes to background")
            }
        }
    }

    @Published private(set) var isLocked = false

    private static let service = "com.klic.mobile.app.applock"
    private static let biometricKey = "applock.biometricEnabled"
    private static let autoLockKey = "applock.autoLock"

    private var backgroundedAt: Date?

    private init() {
        // Locked from launch whenever a passcode is set.
        isLocked = isPasscodeSet
    }

    var isPasscodeSet: Bool { Self.readKeychain("hash") != nil }

    var biometricEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.biometricKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.biometricKey) }
    }

    var autoLock: AutoLock {
        get {
            UserDefaults.standard.string(forKey: Self.autoLockKey)
                .flatMap(AutoLock.init) ?? .immediately
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.autoLockKey) }
    }

    /// Face ID / Touch ID available on this device (and permitted).
    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    // MARK: Passcode management

    /// Stores the passcode as SHA256(salt || code) with a fresh random salt.
    func setPasscode(_ code: String) {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let salt = Data(saltBytes)
        Self.writeKeychain("salt", salt.base64EncodedString())
        Self.writeKeychain("hash", Self.hash(code: code, salt: salt))
        objectWillChange.send()
    }

    func removePasscode() {
        Self.deleteKeychain("salt")
        Self.deleteKeychain("hash")
        biometricEnabled = false
        isLocked = false
        objectWillChange.send()
    }

    func verify(_ code: String) -> Bool {
        guard let saltB64 = Self.readKeychain("salt"),
              let salt = Data(base64Encoded: saltB64),
              let stored = Self.readKeychain("hash") else { return false }
        return Self.hash(code: code, salt: salt) == stored
    }

    private static func hash(code: String, salt: Data) -> String {
        var input = salt
        input.append(Data(code.utf8))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lock lifecycle

    func unlockWithPasscode(_ code: String) -> Bool {
        guard verify(code) else { return false }
        isLocked = false
        return true
    }

    func unlockWithBiometrics() async -> Bool {
        guard biometricEnabled, Self.biometryAvailable else { return false }
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Enter Passcode")
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: String(localized: "Unlock Klic")
            )
            if ok { isLocked = false }
            return ok
        } catch {
            return false
        }
    }

    /// Drive the lock from scene-phase transitions (wired in KlicApp).
    func handleScenePhase(_ phase: ScenePhase) {
        guard isPasscodeSet else { return }
        switch phase {
        case .background, .inactive:
            if backgroundedAt == nil { backgroundedAt = Date() }
            switch autoLock {
            case .immediately:
                isLocked = true
            case .onBackground:
                if phase == .background { isLocked = true }
            default:
                break
            }
        case .active:
            if let since = backgroundedAt {
                let elapsed = Date().timeIntervalSince(since)
                switch autoLock {
                case .oneMinute where elapsed >= 60: isLocked = true
                case .fiveMinutes where elapsed >= 300: isLocked = true
                default: break
                }
            }
            backgroundedAt = nil
        @unknown default:
            break
        }
    }

    // MARK: Keychain primitives (app-private; the lock never syncs anywhere)

    private static func writeKeychain(_ key: String, _ value: String) {
        deleteKeychain(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func readKeychain(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychain(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Lock overlay

/// Full-screen lock overlay: passcode dots + Klic keypad + Face ID shortcut.
struct LockScreenView: View {
    @ObservedObject private var lock = AppLockManager.shared
    @State private var entered = ""
    @State private var shake = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(KlicColor.primary)
            Text("Enter your passcode")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.top, 14)

            PasscodeDots(count: entered.count)
                .padding(.top, 22)
                .offset(x: shake ? -10 : 0)
                .animation(shake ? .spring(response: 0.12, dampingFraction: 0.2) : .default, value: shake)

            PasscodeKeypad(
                showBiometrics: lock.biometricEnabled && AppLockManager.biometryAvailable,
                onDigit: { digit in append(digit) },
                onDelete: { if !entered.isEmpty { entered.removeLast() } },
                onBiometrics: { Task { _ = await lock.unlockWithBiometrics() } }
            )
            .padding(.top, 36)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KlicColor.background.ignoresSafeArea())
        .task {
            // Offer Face ID as soon as the lock appears.
            _ = await lock.unlockWithBiometrics()
        }
    }

    private func append(_ digit: String) {
        guard entered.count < 6 else { return }
        entered += digit
        if entered.count >= 4, lock.verify(entered) {
            _ = lock.unlockWithPasscode(entered)
            entered = ""
            return
        }
        if entered.count == 6 {
            if !lock.unlockWithPasscode(entered) {
                entered = ""
                shake = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { shake = false }
            }
        }
    }
}

struct PasscodeDots: View {
    let count: Int
    var total: Int = 6

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < count ? KlicColor.primary : KlicColor.surfaceRaised)
                    .frame(width: 13, height: 13)
            }
        }
    }
}

struct PasscodeKeypad: View {
    var showBiometrics: Bool = false
    let onDigit: (String) -> Void
    let onDelete: () -> Void
    var onBiometrics: () -> Void = {}

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 16) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { digit in
                        keypadButton(digit) { onDigit(digit) }
                    }
                }
            }
            HStack(spacing: 24) {
                Group {
                    if showBiometrics {
                        Button(action: onBiometrics) {
                            Image(systemName: "faceid")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(KlicColor.primary)
                                .frame(width: 76, height: 76)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 76, height: 76)
                    }
                }
                keypadButton("0") { onDigit("0") }
                Button(action: onDelete) {
                    Image(systemName: "delete.left")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(KlicColor.textPrimary)
                        .frame(width: 76, height: 76)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func keypadButton(_ digit: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(digit)
                .font(KlicFont.headline(28))
                .foregroundStyle(KlicColor.textPrimary)
                .frame(width: 76, height: 76)
                .background(KlicColor.surface, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Passcode & Face ID settings page

struct PasscodeSettingsView: View {
    @ObservedObject private var lock = AppLockManager.shared
    @State private var biometric = AppLockManager.shared.biometricEnabled
    @State private var showAutoLockSheet = false
    @State private var passcodeFlow: PasscodeFlow?

    private enum PasscodeFlow: String, Identifiable {
        case set, change
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    if lock.isPasscodeSet {
                        settingsButton(title: String(localized: "Change Passcode")) { passcodeFlow = .change }
                        Divider().padding(.leading, 20).opacity(0.4)
                        settingsButton(title: String(localized: "Turn Passcode Off"), destructive: true) {
                            lock.removePasscode()
                            biometric = false
                        }
                    } else {
                        settingsButton(title: String(localized: "Turn Passcode On")) { passcodeFlow = .set }
                    }
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                if lock.isPasscodeSet {
                    VStack(spacing: 0) {
                        Toggle(isOn: $biometric) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unlock with Face ID")
                                    .font(KlicFont.body())
                                    .foregroundStyle(KlicColor.textPrimary)
                                if !AppLockManager.biometryAvailable {
                                    Text("Face ID isn't available on this device.")
                                        .font(KlicFont.caption(12))
                                        .foregroundStyle(KlicColor.textMuted)
                                }
                            }
                        }
                        .tint(KlicColor.primary)
                        .disabled(!AppLockManager.biometryAvailable)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .onChange(of: biometric) { _, value in
                            lock.biometricEnabled = value
                        }

                        Divider().padding(.leading, 20).opacity(0.4)

                        Button { showAutoLockSheet = true } label: {
                            HStack {
                                Text("Auto-lock")
                                    .font(KlicFont.body())
                                    .foregroundStyle(KlicColor.textPrimary)
                                Spacer()
                                Text(lock.autoLock.label)
                                    .font(KlicFont.body(14))
                                    .foregroundStyle(KlicColor.textMuted)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(KlicColor.textMuted)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
                }

                Text("Your passcode is stored only on this device. Incoming calls still ring and can be answered while Klic is locked.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Passcode & Face ID")
        .navigationBarTitleDisplayMode(.inline)
        .klicSelectionSheet(
            isPresented: $showAutoLockSheet,
            title: String(localized: "Auto-lock"),
            options: AppLockManager.AutoLock.allCases.map { KlicSheetOption(id: $0.rawValue, label: $0.label) },
            selectedId: lock.autoLock.rawValue
        ) { option in
            if let mode = AppLockManager.AutoLock(rawValue: option.id) {
                lock.autoLock = mode
            }
        }
        .sheet(item: $passcodeFlow) { _ in
            SetPasscodeSheet()
        }
    }

    private func settingsButton(title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(KlicFont.body())
                    .foregroundStyle(destructive ? KlicColor.danger : KlicColor.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Two-step set/change passcode sheet: enter a new 4–6 digit code, then confirm it.
private struct SetPasscodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .enter
    @State private var first = ""
    @State private var entered = ""
    @State private var errorText: String?

    private enum Stage { case enter, confirm }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(stage == .enter ? String(localized: "Enter a new passcode") : String(localized: "Confirm your passcode"))
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)
            Text("4–6 digits")
                .font(KlicFont.caption(12))
                .foregroundStyle(KlicColor.textMuted)
                .padding(.top, 4)

            PasscodeDots(count: entered.count)
                .padding(.top, 20)

            if let errorText {
                Text(errorText)
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.danger)
                    .padding(.top, 10)
            }

            PasscodeKeypad(
                onDigit: { digit in
                    guard entered.count < 6 else { return }
                    errorText = nil
                    entered += digit
                },
                onDelete: { if !entered.isEmpty { entered.removeLast() } }
            )
            .padding(.top, 30)

            PillButton(title: stage == .enter ? String(localized: "Next") : String(localized: "Save Passcode")) {
                advance()
            }
            .opacity(entered.count >= 4 ? 1 : 0.4)
            .disabled(entered.count < 4)
            .padding(.horizontal, 24)
            .padding(.top, 26)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KlicColor.background.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private func advance() {
        switch stage {
        case .enter:
            first = entered
            entered = ""
            stage = .confirm
        case .confirm:
            guard entered == first else {
                errorText = String(localized: "Passcodes don't match. Try again.")
                entered = ""
                first = ""
                stage = .enter
                return
            }
            AppLockManager.shared.setPasscode(entered)
            dismiss()
        }
    }
}

import SwiftUI
import Security
import CryptoKit
import CommonCrypto
import LocalAuthentication

/// Local app lock (§10.4): a 4–6 digit passcode stored as a salted PBKDF2-HMAC-SHA256
/// hash in the Keychain (never server-side; legacy SHA-256 hashes are upgraded on the
/// next successful unlock), failed-attempt lockout, optional Face ID unlock, and an auto-lock
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
    /// End of the current failed-attempt lockout (mirrors the Keychain), nil when none.
    @Published private(set) var lockoutUntil: Date?

    private static let service = "com.klic.mobile.app.applock"
    private static let biometricKey = "applock.biometricEnabled"
    private static let autoLockKey = "applock.autoLock"

    /// Stored hash format: "pbkdf2-sha256$<rounds>$<base64 key>". Anything else is the
    /// legacy hex SHA256(salt || code).
    private static let pbkdf2Marker = "pbkdf2-sha256"
    private static let pbkdf2Rounds: UInt32 = 120_000
    private static let derivedKeyLength = 32
    /// Consecutive failures allowed before lockouts start (30s, 60s, 120s… capped at 1h).
    private static let freeAttempts = 5
    private static let baseLockout: TimeInterval = 30
    private static let maxLockout: TimeInterval = 60 * 60

    private var backgroundedAt: Date?

    private init() {
        // Locked from launch whenever a passcode is set.
        isLocked = isPasscodeSet
        lockoutUntil = Self.readKeychain("lockoutUntil")
            .flatMap { Double($0) }
            .map { Date(timeIntervalSince1970: $0) }
    }

    var isPasscodeSet: Bool { Self.readKeychain("hash") != nil }

    /// Digit count of the passcode, known for hashes written by this version (legacy
    /// hashes have none until their first unlock). Lets the lock screen submit once,
    /// at the right length, so every wrong guess counts toward the lockout.
    var passcodeLength: Int? {
        guard let length = Self.readKeychain("length").flatMap({ Int($0) }),
              (4...6).contains(length) else { return nil }
        return length
    }

    /// Seconds left in the current lockout (0 when entry is allowed).
    func lockoutRemaining(now: Date = Date()) -> TimeInterval {
        guard let lockoutUntil else { return 0 }
        // Clamp so a clock moved backwards can't extend the lockout past the cap.
        return min(max(0, lockoutUntil.timeIntervalSince(now)), Self.maxLockout)
    }

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

    /// Stores the passcode as PBKDF2-HMAC-SHA256(code, salt) with a fresh random salt.
    func setPasscode(_ code: String) {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess,
              let derived = Self.pbkdf2(code: code, salt: Data(saltBytes), rounds: Self.pbkdf2Rounds)
        else { return }
        let salt = Data(saltBytes)
        Self.writeKeychain("salt", salt.base64EncodedString())
        Self.writeKeychain("hash", "\(Self.pbkdf2Marker)$\(Self.pbkdf2Rounds)$\(derived.base64EncodedString())")
        Self.writeKeychain("length", String(code.count))
        resetFailures()
        objectWillChange.send()
    }

    func removePasscode() {
        Self.deleteKeychain("salt")
        Self.deleteKeychain("hash")
        Self.deleteKeychain("length")
        resetFailures()
        biometricEnabled = false
        isLocked = false
        objectWillChange.send()
    }

    /// §13.12: the app lock never survives a transition to the signed-out state —
    /// logout, account deletion, or a server-rejected refresh all wipe the passcode
    /// hash, the biometric toggle AND the auto-lock preference.
    func clearForSignOut() {
        removePasscode()
        UserDefaults.standard.removeObject(forKey: Self.autoLockKey)
        backgroundedAt = nil
    }

    /// Checks `code` against the stored hash (no lockout bookkeeping). A matching legacy
    /// SHA-256 hash is transparently re-hashed with PBKDF2.
    func verify(_ code: String) -> Bool {
        guard let saltB64 = Self.readKeychain("salt"),
              let salt = Data(base64Encoded: saltB64),
              let stored = Self.readKeychain("hash") else { return false }

        if stored.hasPrefix(Self.pbkdf2Marker + "$") {
            let parts = stored.split(separator: "$")
            guard parts.count == 3,
                  let rounds = UInt32(parts[1]),
                  let expected = Data(base64Encoded: String(parts[2])),
                  let derived = Self.pbkdf2(code: code, salt: salt, rounds: rounds)
            else { return false }
            return Self.constantTimeEquals(derived, expected)
        }

        // Legacy: hex SHA256(salt || code).
        guard Self.constantTimeEquals(Data(Self.legacyHash(code: code, salt: salt).utf8), Data(stored.utf8))
        else { return false }
        setPasscode(code)
        return true
    }

    private static func legacyHash(code: String, salt: Data) -> String {
        var input = salt
        input.append(Data(code.utf8))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func pbkdf2(code: String, salt: Data, rounds: UInt32) -> Data? {
        var derived = [UInt8](repeating: 0, count: Self.derivedKeyLength)
        let password = Array(code.utf8CString) // NUL-terminated; length excludes the NUL
        let status = salt.withUnsafeBytes { (saltBuffer: UnsafeRawBufferPointer) -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, password.count - 1,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, saltBuffer.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                rounds,
                &derived, Self.derivedKeyLength
            )
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return Data(derived)
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    // MARK: Failed-attempt lockout (persisted in the Keychain so a relaunch doesn't reset it)

    private func recordFailure() {
        let failures = (Self.readKeychain("failures").flatMap { Int($0) } ?? 0) + 1
        Self.writeKeychain("failures", String(failures))
        guard failures >= Self.freeAttempts else { return }
        let exponent = min(failures - Self.freeAttempts, 7) // 30s · 2^7 already exceeds the cap
        let delay = min(Self.baseLockout * Double(1 << exponent), Self.maxLockout)
        let until = Date().addingTimeInterval(delay)
        Self.writeKeychain("lockoutUntil", String(until.timeIntervalSince1970))
        lockoutUntil = until
    }

    private func resetFailures() {
        Self.deleteKeychain("failures")
        Self.deleteKeychain("lockoutUntil")
        lockoutUntil = nil
    }

    // MARK: Lock lifecycle

    /// Verifies and unlocks. Refused outright during a lockout. `countFailure: false`
    /// is for the legacy prefix probes (4/5 digits of a possibly 6-digit code).
    func unlockWithPasscode(_ code: String, countFailure: Bool = true) -> Bool {
        guard lockoutRemaining() <= 0 else { return false }
        guard verify(code) else {
            if countFailure { recordFailure() }
            return false
        }
        resetFailures()
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
            if ok {
                resetFailures()
                isLocked = false
            }
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

/// §11.3 lock overlay: the app content behind is FULLY blurred (RootView blurs the
/// content itself and this adds a heavy material wash — unreadable), with the
/// passcode entry presented as a Klic-styled bottom sheet card. Rendered UNDER the
/// call fullScreenCover so incoming CallKit call UI keeps bypassing the lock.
struct LockScreenView: View {
    @ObservedObject private var lock = AppLockManager.shared
    @State private var entered = ""
    @State private var shake = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Privacy backdrop — never a plain dim (§11.3).
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            KlicColor.background.opacity(0.45)
                .ignoresSafeArea()

            // Klic-styled sheet card.
            VStack(spacing: 0) {
                Capsule()
                    .fill(KlicColor.textMuted.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)

                Image(systemName: "lock.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(KlicColor.primary)
                    .padding(.top, 22)
                Text("Enter your passcode")
                    .font(KlicFont.headline(17))
                    .foregroundStyle(KlicColor.textPrimary)
                    .padding(.top, 12)

                // Failed-attempt lockout countdown (re-evaluated every second).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = lock.lockoutRemaining(now: context.date)
                    if remaining > 0 {
                        Text("Try again in \(Int(remaining.rounded(.up))) s")
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.danger)
                            .padding(.top, 8)
                    }
                }

                PasscodeDots(count: entered.count)
                    .padding(.top, 20)
                    .offset(x: shake ? -10 : 0)
                    .animation(shake ? .spring(response: 0.12, dampingFraction: 0.2) : .default, value: shake)

                PasscodeKeypad(
                    showBiometrics: lock.biometricEnabled && AppLockManager.biometryAvailable,
                    onDigit: { digit in append(digit) },
                    onDelete: { if !entered.isEmpty { entered.removeLast() } },
                    onBiometrics: { Task { _ = await lock.unlockWithBiometrics() } }
                )
                .padding(.top, 30)
                .padding(.bottom, 34)
            }
            .frame(maxWidth: .infinity)
            .background(
                KlicColor.background,
                in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
            )
        }
        .task {
            // Offer Face ID as soon as the lock appears.
            _ = await lock.unlockWithBiometrics()
        }
    }

    private func append(_ digit: String) {
        guard lock.lockoutRemaining() <= 0 else { return }
        guard entered.count < 6 else { return }
        entered += digit
        if let length = lock.passcodeLength {
            // Known length: one attempt per entry, and every miss counts.
            guard entered.count == length else { return }
            if lock.unlockWithPasscode(entered) { entered = "" } else { reject() }
            return
        }
        // Legacy hash (length unknown until the first unlock re-hashes it): probe at
        // 4 and 5 digits without counting, count a miss only at 6.
        guard entered.count >= 4 else { return }
        if lock.unlockWithPasscode(entered, countFailure: entered.count == 6) {
            entered = ""
        } else if entered.count == 6 {
            reject()
        }
    }

    private func reject() {
        entered = ""
        shake = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { shake = false }
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
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        // §11.3: while the set/change sheet is up the page behind is fully blurred.
        .blur(radius: passcodeFlow != nil ? 26 : 0)
        .animation(.easeInOut(duration: 0.2), value: passcodeFlow != nil)
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

/// Two-step set/change passcode sheet (§11.3, Klic-styled): enter a new 4–6 digit
/// code, then confirm it. The presenting page blurs itself while this is up.
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
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .padding(.bottom, 12)
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(KlicColor.background)
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

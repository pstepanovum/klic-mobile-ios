import SwiftUI

/// What a report points at (§12.1). `problem` is the target-less variant used by
/// Settings → "Report a problem".
enum ReportTarget: Identifiable {
    case user(id: String, username: String, displayName: String)
    case message(id: String, senderId: String?, senderUsername: String?, senderDisplayName: String?)
    case problem

    var id: String {
        switch self {
        case .user(let id, _, _):       return "user-\(id)"
        case .message(let id, _, _, _): return "message-\(id)"
        case .problem:                  return "problem"
        }
    }

    /// The user a post-submit "Block @user" shortcut would block (user/message reports).
    var blockCandidate: (id: String, username: String)? {
        switch self {
        case .user(let id, let username, _):
            return (id, username)
        case .message(_, let senderId, let senderUsername, _):
            guard let senderId, let senderUsername else { return nil }
            return (senderId, senderUsername)
        case .problem:
            return nil
        }
    }
}

/// The one Klic report flow (§12.1): category list → optional details → submit →
/// confirmation offering one-tap "Block @user" for user/message reports.
struct ReportSheet: View {
    let target: ReportTarget

    @Environment(\.dismiss) private var dismiss
    @State private var category: ReportCategory?
    @State private var details = ""
    @State private var submitting = false
    @State private var error: String?
    @State private var submitted = false
    @State private var blocking = false
    @State private var blocked = false
    @FocusState private var detailsFocused: Bool

    private static let detailsLimit = 1000

    var body: some View {
        VStack(spacing: 0) {
            header
            if submitted {
                confirmation
            } else if let category {
                detailsStep(category)
            } else {
                categoryStep
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(KlicColor.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(KlicColor.background)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 4) {
            Text(submitted ? String(localized: "Report submitted") : String(localized: "Report"))
                .font(KlicFont.headline(16))
                .foregroundStyle(KlicColor.textPrimary)
            if !submitted {
                Text(subtitle)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var subtitle: String {
        switch target {
        case .user(_, let username, _):
            return String(localized: "Why are you reporting @\(username)?")
        case .message:
            return String(localized: "Why are you reporting this message?")
        case .problem:
            return String(localized: "Tell us what went wrong. Reports are anonymous to other users.")
        }
    }

    // MARK: Step 1 — category

    private var categoryStep: some View {
        VStack(spacing: 14) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(ReportCategory.allCases.enumerated()), id: \.element.id) { index, item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { category = item }
                        } label: {
                            HStack {
                                Text(item.label)
                                    .font(KlicFont.body())
                                    .foregroundStyle(KlicColor.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(KlicColor.textMuted)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < ReportCategory.allCases.count - 1 {
                            Divider().padding(.leading, 20).opacity(0.4)
                        }
                    }
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16)
            }

            PillButton(title: String(localized: "Cancel"), fill: KlicColor.surfaceRaised, textColor: KlicColor.textMuted) {
                dismiss()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: Step 2 — optional details + submit

    private func detailsStep(_ category: ReportCategory) -> some View {
        VStack(spacing: 14) {
            // Chosen category — tap to go back and change it.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { self.category = nil }
            } label: {
                HStack {
                    Text(category.label)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    Spacer()
                    Text("Change")
                        .font(KlicFont.caption(13))
                        .foregroundStyle(KlicColor.primary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                TextField(String(localized: "Add details (optional)"), text: $details, axis: .vertical)
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.textPrimary)
                    .tint(KlicColor.primary)
                    .lineLimit(4, reservesSpace: true)
                    .focused($detailsFocused)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
                    .onChange(of: details) { _, value in
                        if value.count > Self.detailsLimit { details = String(value.prefix(Self.detailsLimit)) }
                    }
                Text(verbatim: "\(details.count)/\(Self.detailsLimit)")
                    .font(KlicFont.caption(11))
                    .foregroundStyle(KlicColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 6)
            }

            if let error {
                Text(error)
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            PillButton(title: String(localized: "Submit report"), isLoading: submitting) {
                Task { await submit(category) }
            }

            PillButton(title: String(localized: "Cancel"), fill: KlicColor.surfaceRaised, textColor: KlicColor.textMuted) {
                dismiss()
            }
            .padding(.bottom, 12)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Step 3 — confirmation (+ optional one-tap block)

    private var confirmation: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .padding(.top, 18)

            Text("Thanks for letting us know. Our team will review your report.")
                .font(KlicFont.body(14))
                .foregroundStyle(KlicColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let error {
                Text(error)
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            if let candidate = target.blockCandidate {
                if blocked {
                    Text("@\(candidate.username) is blocked. Manage blocked users in Settings → Privacy and Security.")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                } else {
                    PillButton(
                        title: String(localized: "Block @\(candidate.username)"),
                        fill: KlicColor.surface,
                        textColor: KlicColor.danger,
                        isLoading: blocking
                    ) {
                        Task { await block(candidate.id) }
                    }
                    .padding(.horizontal, 16)
                }
            }

            PillButton(title: String(localized: "Done")) {
                dismiss()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: Actions

    private func submit(_ category: ReportCategory) async {
        submitting = true
        defer { submitting = false }
        error = nil
        detailsFocused = false
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var targetUserId: String?
            var messageId: String?
            switch target {
            case .user(let id, _, _):       targetUserId = id
            case .message(let id, _, _, _): messageId = id
            case .problem:                  break
            }
            _ = try await APIClient.shared.submitReport(
                targetUserId: targetUserId,
                messageId: messageId,
                category: category.rawValue,
                details: trimmed.isEmpty ? nil : trimmed
            )
            withAnimation(.easeInOut(duration: 0.2)) { submitted = true }
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = String(localized: "Couldn't send the report. Please try again.")
        }
    }

    private func block(_ userId: String) async {
        blocking = true
        defer { blocking = false }
        error = nil
        do {
            _ = try await APIClient.shared.blockUser(userId: userId)
            ChatCaches.friends.removeAll { $0.id == userId }
            withAnimation(.easeInOut(duration: 0.2)) { blocked = true }
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = String(localized: "Couldn't block this user right now.")
        }
    }
}

extension View {
    /// Presents the shared report flow (§12.1) for an optional `ReportTarget`.
    func reportSheet(target: Binding<ReportTarget?>) -> some View {
        sheet(item: target) { ReportSheet(target: $0) }
    }
}

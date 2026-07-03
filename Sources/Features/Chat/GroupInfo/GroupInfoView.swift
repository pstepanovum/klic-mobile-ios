import SwiftUI
import PhotosUI
import Inject

/// Group Info (§9.3): rounded Klic cards — cover/title, quick actions, members (with
/// admin remove), media/starred/storage, notifications, danger zone, created footer.
struct GroupInfoView: View {
    @ObserveInjection var inject
    let conversationId: String
    let title: String
    let initialDetails: GroupConversationDetails?
    let fallbackMembers: [ChatProfileTarget]
    let onSelectMember: (ChatProfileTarget) -> Void
    let onUpdated: (GroupConversationDetails) -> Void
    let onDeleted: () -> Void
    /// Starts (or joins) the group call via the chat's existing flows. "AUDIO" | "VIDEO".
    var onStartCall: (String) -> Void = { _ in }
    /// Opens the chat's message-search sheet (the info page dismisses itself first).
    var onSearchMessages: () -> Void = {}

    var body: some View {
        GroupInfoContent(
            conversationId: conversationId,
            fallbackTitle: title,
            initialDetails: initialDetails,
            fallbackMembers: fallbackMembers,
            onSelectMember: onSelectMember,
            onUpdated: onUpdated,
            onDeleted: onDeleted,
            onStartCall: onStartCall,
            onSearchMessages: onSearchMessages
        )
        .enableInjection()
    }
}

private struct GroupInfoContent: View {
    @ObserveInjection var inject
    let conversationId: String
    let fallbackTitle: String
    let initialDetails: GroupConversationDetails?
    let fallbackMembers: [ChatProfileTarget]
    let onSelectMember: (ChatProfileTarget) -> Void
    let onUpdated: (GroupConversationDetails) -> Void
    let onDeleted: () -> Void
    let onStartCall: (String) -> Void
    let onSearchMessages: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var details: GroupConversationDetails?
    @State private var loading = false
    @State private var editing = false
    @State private var editTitle = ""
    @State private var editDescription = ""
    @State private var memberQuery = ""
    @State private var addSheet = false
    @State private var pickedCover: PhotosPickerItem?
    @State private var savingCover = false
    /// Visible cover-upload failure (§10.1) — presented as an alert, never swallowed.
    @State private var coverAlert: String?
    @State private var leaving = false
    @State private var error: String?
    @State private var showDeleteDialog = false
    // Admin remove-member flow (§9.3): action sheet → confirm sheet → DELETE.
    @State private var memberActionTarget: GroupConversationDetails.Member?
    @State private var removeConfirmTarget: GroupConversationDetails.Member?
    @State private var removingMemberIds: Set<String> = []

    private var resolvedDetails: GroupConversationDetails? { details ?? initialDetails }
    private var resolvedTitle: String { resolvedDetails?.title?.trimmingCharacters(in: .whitespaces).isEmpty == false ? (resolvedDetails?.title ?? fallbackTitle) : fallbackTitle }
    private var resolvedDescription: String? {
        guard let text = resolvedDetails?.description?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
    private var isAdmin: Bool { resolvedDetails?.isAdmin == true }
    private var members: [GroupConversationDetails.Member] {
        if let loaded = resolvedDetails?.members, !loaded.isEmpty {
            return loaded
        }
        return fallbackMembers.map {
            GroupConversationDetails.Member(
                id: $0.id,
                username: $0.username,
                displayName: $0.displayName,
                avatarUrl: $0.avatarUrl,
                joinedAt: "",
                isMe: false
            )
        }
    }
    private var filteredMembers: [GroupConversationDetails.Member] {
        let q = memberQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter {
            $0.displayName.lowercased().contains(q) || $0.username.lowercased().contains(q)
        }
    }

    private var createdByName: String? {
        guard let creatorId = resolvedDetails?.createdById else { return nil }
        if let member = members.first(where: { $0.id == creatorId }) {
            return member.isMe ? String(localized: "you") : member.displayName
        }
        return fallbackMembers.first(where: { $0.id == creatorId })?.displayName
    }

    private var createdAtText: String? {
        guard let date = ChatLocalPrefs.parseISO(resolvedDetails?.createdAt) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSection
                actionsRow

                if editing {
                    editCard
                }

                membersCard

                // Media / Starred / Manage storage / Save to Photos + Notifications (§8.4)
                ChatInfoCommonRows(
                    conversationId: conversationId,
                    members: fallbackMembers.isEmpty
                        ? members.map { ChatProfileTarget(id: $0.id, username: $0.username, displayName: $0.displayName, avatarUrl: $0.avatarUrl) }
                        : fallbackMembers
                )

                ChatNotificationsCard(conversationId: conversationId, isGroup: true)

                dangerZone

                if let error {
                    Text(error)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.danger)
                        .multilineTextAlignment(.center)
                }

                // Footer: who created the group and when (§8.4).
                if createdByName != nil || createdAtText != nil {
                    VStack(alignment: .center, spacing: 2) {
                        if let createdByName {
                            Text("Created by \(createdByName)")
                        }
                        if let createdAtText {
                            Text("Created \(createdAtText)")
                        }
                    }
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                }
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Group Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "Done" : "Edit") {
                        if editing {
                            editing = false
                        } else {
                            editTitle = resolvedDetails?.title ?? fallbackTitle
                            editDescription = resolvedDetails?.description ?? ""
                            editing = true
                        }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $addSheet) {
            AddGroupMembersSheet(conversationId: conversationId, currentMemberIds: Set(members.map(\.id))) { updated in
                apply(updated)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            String(localized: "Group cover"),
            isPresented: Binding(get: { coverAlert != nil }, set: { if !$0 { coverAlert = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) { coverAlert = nil }
        } message: {
            Text(coverAlert ?? "")
        }
        .onChange(of: pickedCover) { _, item in
            guard let item else { return }
            Task {
                await uploadCover(item)
                // Reset the selection or picking the SAME photo again never fires
                // onChange — this is what made re-uploading a cover look broken.
                pickedCover = nil
            }
        }
        .klicSelectionSheet(
            isPresented: $showDeleteDialog,
            title: String(localized: "Delete this group?"),
            message: String(localized: "This removes the group chat and all of its messages for everyone."),
            options: [KlicSheetOption(id: "delete", label: String(localized: "Delete Group"), isDestructive: true)]
        ) { _ in
            Task { await deleteGroup() }
        }
        // Member sheet: profile for everyone; admins also get "Remove from group" (§9.3).
        .klicSelectionSheet(
            isPresented: Binding(
                get: { memberActionTarget != nil },
                set: { if !$0 { memberActionTarget = nil } }
            ),
            title: memberActionTarget?.displayName ?? "Member",
            message: memberActionTarget.map { "@\($0.username)" },
            options: [
                KlicSheetOption(id: "profile", label: String(localized: "View profile")),
                KlicSheetOption(id: "remove", label: String(localized: "Remove from group"), isDestructive: true),
            ]
        ) { option in
            guard let member = memberActionTarget else { return }
            memberActionTarget = nil
            switch option.id {
            case "profile":
                openProfile(member)
            case "remove":
                // Chain the confirm sheet after this one fully dismisses.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    removeConfirmTarget = member
                }
            default:
                break
            }
        }
        .klicSelectionSheet(
            isPresented: Binding(
                get: { removeConfirmTarget != nil },
                set: { if !$0 { removeConfirmTarget = nil } }
            ),
            title: String(localized: "Remove \(removeConfirmTarget?.displayName ?? "member")?"),
            message: String(localized: "They will no longer see this group or its messages."),
            options: [KlicSheetOption(id: "remove", label: String(localized: "Remove from group"), isDestructive: true)]
        ) { _ in
            guard let member = removeConfirmTarget else { return }
            removeConfirmTarget = nil
            Task { await removeMember(member) }
        }
        .enableInjection()
    }

    // MARK: Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            coverPicker
            VStack(spacing: 6) {
                Text(resolvedTitle)
                    .font(KlicFont.headline(22))
                    .foregroundStyle(KlicColor.textPrimary)
                    .multilineTextAlignment(.center)
                if let description = resolvedDescription {
                    Text(description)
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                }
                Text(members.count == 1 ? String(localized: "1 member") : String(localized: "\(members.count) members"))
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var coverPicker: some View {
        if isAdmin {
            PhotosPicker(selection: $pickedCover, matching: .images) {
                coverView.overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KlicColor.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(KlicColor.primary, in: Circle())
                        .overlay(Circle().stroke(KlicColor.background, lineWidth: 3))
                        .padding(6)
                }
            }
            .buttonStyle(.plain)
        } else {
            coverView
        }
    }

    private var coverView: some View {
        AvatarView(url: resolvedDetails?.avatarUrl, name: resolvedTitle, size: 104)
            .overlay {
                if savingCover {
                    ProgressView()
                        .tint(KlicColor.primary)
                }
            }
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 12) {
            actionButton(title: String(localized: "Audio"), systemName: "phone.fill") {
                onStartCall("AUDIO")
                dismiss()
            }
            actionButton(title: String(localized: "Video"), systemName: "video.fill") {
                onStartCall("VIDEO")
                dismiss()
            }
            actionButton(title: String(localized: "Add"), systemName: "person.badge.plus.fill", disabled: !isAdmin) {
                addSheet = true
            }
            // Message search over the chat's history (CALLS.md §8.4).
            actionButton(title: String(localized: "Search"), systemName: "magnifyingglass") {
                onSearchMessages()
                dismiss()
            }
        }
    }

    private func actionButton(title: String, systemName: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(disabled ? KlicColor.textMuted : KlicColor.onPrimary)
                    .frame(width: 48, height: 48)
                    .background(disabled ? KlicColor.surfaceRaised : KlicColor.primary, in: Circle())
                Text(title)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: Edit (admin)

    private var editCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit group")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)
            KlicTextField(placeholder: String(localized: "Group name"), text: $editTitle)
            TextField("Description", text: $editDescription, axis: .vertical)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
                .tint(KlicColor.primary)
                .lineLimit(3, reservesSpace: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(KlicColor.background, in: RoundedRectangle(cornerRadius: 20))
            PillButton(title: String(localized: "Save changes")) { Task { await saveEdits() } }
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Members

    private var membersCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Members")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 8)

            KlicSearchField(placeholder: String(localized: "Search members"), text: $memberQuery)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            ForEach(Array(filteredMembers.prefix(6).enumerated()), id: \.element.id) { index, member in
                memberRow(member)
                if index < min(filteredMembers.count, 6) - 1 {
                    Divider().padding(.leading, 74).opacity(0.4)
                }
            }

            if filteredMembers.isEmpty {
                Text("No members match.")
                    .font(KlicFont.body(14))
                    .foregroundStyle(KlicColor.textMuted)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }

            if filteredMembers.count > 6 {
                Divider().padding(.leading, 18).opacity(0.4)
                NavigationLink {
                    GroupMemberListView(
                        members: filteredMembers,
                        canRemove: isAdmin ? { canRemove($0) } : { _ in false },
                        onSelectMember: onSelectMember,
                        onRemove: { member in removeConfirmTarget = member }
                    )
                } label: {
                    HStack {
                        Text("View all members")
                            .font(KlicFont.body())
                            .foregroundStyle(KlicColor.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(height: 8)
            }
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    /// Admins can remove anyone who isn't themselves and isn't the admin (§9.3).
    private func canRemove(_ member: GroupConversationDetails.Member) -> Bool {
        isAdmin && !member.isMe && member.id != resolvedDetails?.createdById
    }

    private func memberRow(_ member: GroupConversationDetails.Member) -> some View {
        Button {
            if canRemove(member) {
                memberActionTarget = member
            } else {
                openProfile(member)
            }
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: member.avatarUrl, name: member.displayName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.displayName)
                            .font(KlicFont.medium())
                            .foregroundStyle(KlicColor.textPrimary)
                        if member.isMe {
                            Text("You")
                                .font(KlicFont.caption(11))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        if member.id == resolvedDetails?.createdById {
                            Text("Admin")
                                .font(KlicFont.caption(10).weight(.semibold))
                                .foregroundStyle(KlicColor.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(KlicColor.primary.opacity(0.12), in: Capsule())
                        }
                    }
                    Text("@\(member.username)")
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                }
                Spacer()
                if removingMemberIds.contains(member.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(removingMemberIds.contains(member.id))
    }

    private func openProfile(_ member: GroupConversationDetails.Member) {
        onSelectMember(ChatProfileTarget(id: member.id, username: member.username, displayName: member.displayName, avatarUrl: member.avatarUrl))
    }

    // MARK: Danger zone

    private var dangerZone: some View {
        Group {
            if isAdmin {
                PillButton(title: String(localized: "Delete Group"), fill: KlicColor.surface, textColor: KlicColor.danger) {
                    showDeleteDialog = true
                }
            } else {
                PillButton(title: leaving ? "Leaving…" : "Exit Group", fill: KlicColor.surface, textColor: KlicColor.danger) {
                    Task { await leaveGroup() }
                }
                .disabled(leaving)
            }
        }
    }

    // MARK: Data

    private func load() async {
        loading = true
        defer { loading = false }
        if let fetched = try? await APIClient.shared.conversationDetails(id: conversationId) {
            apply(fetched)
        }
    }

    /// Optimistic removal (§9.3): the row disappears immediately; the DELETE reconciles
    /// (restore + error on failure). Body-less DELETE — the client sends no Content-Type.
    private func removeMember(_ member: GroupConversationDetails.Member) async {
        guard let current = resolvedDetails else { return }
        removingMemberIds.insert(member.id)
        defer { removingMemberIds.remove(member.id) }
        apply(current.removingMember(member.id))
        do {
            try await APIClient.shared.removeGroupMember(conversationId: conversationId, userId: member.id)
        } catch let e as APIError {
            apply(current)   // restore the row
            error = e.userMessage
        } catch {
            apply(current)
            self.error = "Couldn't remove \(member.displayName)."
        }
    }

    private func saveEdits() async {
        guard let current = resolvedDetails else { return }
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let description = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = try await APIClient.shared.updateGroupConversation(
                id: conversationId,
                title: title,
                description: description.isEmpty ? nil : description
            )
            editing = false
            apply(updated)
        } catch let e as APIError {
            self.error = e.userMessage
            apply(current)
        } catch {
            self.error = "Couldn't save the group right now."
        }
    }

    /// §10.1: every step of the cover chain (read → presign → PUT → PATCH) surfaces
    /// its own visible alert + a diagnostic event; nothing is silently swallowed.
    private func uploadCover(_ item: PhotosPickerItem) async {
        savingCover = true
        defer { savingCover = false }
        error = nil

        let jpeg: Data
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                coverFailed(step: "read", message: String(localized: "Couldn't read the selected photo."))
                return
            }
            guard let (encoded, _, _) = Media.encodeImage(image) else {
                coverFailed(step: "encode", message: String(localized: "Couldn't process the selected photo."))
                return
            }
            jpeg = encoded
        } catch {
            coverFailed(step: "read", message: String(localized: "Couldn't read the selected photo."), detail: "\(error)")
            return
        }

        let ticket: UploadTicket
        do {
            ticket = try await APIClient.shared.requestGroupAvatarUpload(
                conversationId: conversationId,
                contentType: "image/jpeg",
                byteSize: jpeg.count
            )
        } catch {
            coverFailed(
                step: "presign",
                message: String(localized: "Couldn't start the cover upload: ") + Self.describe(error),
                detail: "\(error)"
            )
            return
        }

        do {
            try await APIClient.shared.uploadData(jpeg, to: ticket.uploadUrl, contentType: "image/jpeg")
        } catch {
            coverFailed(
                step: "put",
                message: String(localized: "Couldn't upload the cover image: ") + Self.describe(error),
                detail: "\(error)"
            )
            return
        }

        do {
            let updated = try await APIClient.shared.updateGroupConversation(id: conversationId, avatarKey: ticket.key)
            apply(updated)
            APIClient.mobileDiagnostic(event: "group-cover-updated", detail: conversationId)
        } catch {
            coverFailed(
                step: "patch",
                message: String(localized: "The cover uploaded but couldn't be saved: ") + Self.describe(error),
                detail: "\(error)"
            )
        }
    }

    private func coverFailed(step: String, message: String, detail: String? = nil) {
        coverAlert = message
        APIClient.mobileDiagnostic(
            event: "group-cover-failed-\(step)",
            detail: "\(conversationId) \(detail ?? "")"
        )
    }

    private static func describe(_ error: Error) -> String {
        if let apiError = error as? APIError { return apiError.userMessage }
        return (error as NSError).localizedDescription
    }

    private func leaveGroup() async {
        leaving = true
        defer { leaving = false }
        do {
            _ = try await APIClient.shared.leaveGroup(conversationId: conversationId)
            ConversationStore.shared.remove(conversationId: conversationId)
            dismiss()
        } catch let e as APIError {
            self.error = e.userMessage
        } catch {
            self.error = "Couldn't leave the group."
        }
    }

    private func deleteGroup() async {
        leaving = true
        defer { leaving = false }
        do {
            _ = try await APIClient.shared.deleteGroup(conversationId: conversationId)
            ConversationStore.shared.remove(conversationId: conversationId)
            onDeleted()
            dismiss()
        } catch let e as APIError {
            self.error = e.userMessage
        } catch {
            self.error = "Couldn't delete the group."
        }
    }

    private func apply(_ updated: GroupConversationDetails) {
        details = updated
        ChatCaches.groupDetails[conversationId] = updated
        // §10.1: reflect title/cover edits into the cached conversations list so the
        // Chats tab row updates in place, no refetch needed.
        ConversationStore.shared.applyGroupDetails(updated)
        onUpdated(updated)
        editTitle = updated.title ?? fallbackTitle
        editDescription = updated.description ?? ""
        error = nil
    }
}

private extension GroupConversationDetails {
    func removingMember(_ memberId: String) -> GroupConversationDetails {
        GroupConversationDetails(
            id: id, type: type, title: title, description: description,
            avatarUrl: avatarUrl, createdById: createdById, createdAt: createdAt,
            isAdmin: isAdmin, members: members.filter { $0.id != memberId }
        )
    }
}

private struct GroupMemberListView: View {
    let members: [GroupConversationDetails.Member]
    let canRemove: (GroupConversationDetails.Member) -> Bool
    let onSelectMember: (ChatProfileTarget) -> Void
    let onRemove: (GroupConversationDetails.Member) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [GroupConversationDetails.Member] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter {
            $0.displayName.lowercased().contains(q) || $0.username.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                KlicSearchField(placeholder: String(localized: "Search members"), text: $query)

                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, member in
                        Button {
                            onSelectMember(ChatProfileTarget(id: member.id, username: member.username, displayName: member.displayName, avatarUrl: member.avatarUrl))
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: member.avatarUrl, name: member.displayName, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.displayName)
                                        .font(KlicFont.medium())
                                        .foregroundStyle(KlicColor.textPrimary)
                                    Text("@\(member.username)")
                                        .font(KlicFont.caption())
                                        .foregroundStyle(KlicColor.textMuted)
                                }
                                Spacer()
                                if canRemove(member) {
                                    Button {
                                        // Confirm sheet lives on the parent page — pop
                                        // back exactly one level, then present (§9.4).
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                            onRemove(member)
                                        }
                                    } label: {
                                        Text("Remove")
                                            .font(KlicFont.medium(13))
                                            .foregroundStyle(KlicColor.danger)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(KlicColor.danger.opacity(0.1), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < filtered.count - 1 {
                            Divider().padding(.leading, 74).opacity(0.4)
                        }
                    }
                }
                .padding(.vertical, 8)
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AddGroupMembersSheet: View {
    let conversationId: String
    let currentMemberIds: Set<String>
    let onUpdated: (GroupConversationDetails) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var friends: [User] = []
    @State private var selectedIds: Set<String> = []
    @State private var loading = false
    @State private var saving = false

    private var availableFriends: [User] {
        friends.filter { !currentMemberIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(availableFriends) { friend in
                Button {
                    if selectedIds.contains(friend.id) { selectedIds.remove(friend.id) }
                    else { selectedIds.insert(friend.id) }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: friend.avatarUrl, name: friend.displayName, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.displayName)
                                .font(KlicFont.medium())
                                .foregroundStyle(KlicColor.textPrimary)
                            Text("@\(friend.username)")
                                .font(KlicFont.caption())
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        Spacer()
                        Image(systemName: selectedIds.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(selectedIds.contains(friend.id) ? KlicColor.primary : KlicColor.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(KlicColor.surface)
            }
            .overlay {
                if loading {
                    ProgressView()
                } else if availableFriends.isEmpty {
                    Text("No more friends to add.")
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Add members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Adding…" : "Add") { Task { await addMembers() } }
                        .disabled(selectedIds.isEmpty || saving)
                }
            }
            .task { await loadFriends() }
        }
    }

    private func loadFriends() async {
        loading = true
        defer { loading = false }
        friends = (try? await APIClient.shared.friends()) ?? []
    }

    private func addMembers() async {
        saving = true
        defer { saving = false }
        guard let updated = try? await APIClient.shared.addGroupMembers(conversationId: conversationId, userIds: Array(selectedIds)) else { return }
        onUpdated(updated)
        dismiss()
    }
}

import SwiftUI
import PhotosUI
import Inject

/// Edit the current user's profile: photo (with the §11.5 adjust step), display name,
/// username (§11.4), About presets/custom (§11.5) and Links (§11.5).
struct EditProfileView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var username = ""
    @State private var pickedItem: PhotosPickerItem?
    /// Raw pick → adjust sheet; the cropped result is what uploads.
    @State private var adjustingImage: UIImage?
    @State private var pickedImage: UIImage?
    @State private var saving = false
    @State private var error: String?

    // About (§11.5)
    @State private var about: String?
    @State private var showAboutSheet = false
    @State private var showCustomAbout = false
    @State private var savingAbout = false

    // Links (§11.5)
    @State private var links: [String] = []
    @State private var linkEditor: LinkEditorTarget?
    @State private var linkActionIndex: Int?
    @State private var savingLinks = false

    private struct LinkEditorTarget: Identifiable {
        let index: Int?          // nil = adding a new link
        let initial: String
        var id: String { index.map(String.init) ?? "new" }
    }

    static let aboutPresets: [String] = [
        String(localized: "Free to chat"),
        String(localized: "Slow to respond"),
        String(localized: "Traveling"),
        String(localized: "At work"),
        String(localized: "Busy"),
        String(localized: "Battery about to die"),
    ]

    private static let usernamePattern = "^[a-z0-9_.]{3,32}$"

    var body: some View {
        let user = session.currentUser
        ScrollView {
            VStack(spacing: 22) {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        if let pickedImage {
                            Image(uiImage: pickedImage).resizable().scaledToFill()
                                .frame(width: 120, height: 120).clipShape(Circle())
                        } else {
                            AvatarView(url: user?.avatarUrl,
                                       name: user?.displayName ?? "", size: 120)
                        }
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KlicColor.onPrimary)
                            .frame(width: 34, height: 34)
                            .background(KlicColor.primary, in: Circle())
                            .overlay(Circle().stroke(KlicColor.background, lineWidth: 3))
                    }
                }
                .padding(.top, 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Display name")
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                    TextField("Display name", text: $displayName)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                        .tint(KlicColor.primary)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(KlicColor.surfaceRaised, in: Capsule())
                }

                // Username (§11.4): editable, @-prefixed, inline validation.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Username")
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                    HStack(spacing: 2) {
                        Text(verbatim: "@")
                            .font(KlicFont.body())
                            .foregroundStyle(KlicColor.textMuted)
                        TextField("username", text: $username)
                            .font(KlicFont.body())
                            .foregroundStyle(KlicColor.textPrimary)
                            .tint(KlicColor.primary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: username) { _, value in
                                let cleaned = value.lowercased().filter { "abcdefghijklmnopqrstuvwxyz0123456789_.".contains($0) }
                                if cleaned != value { username = cleaned }
                            }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(KlicColor.surfaceRaised, in: Capsule())
                    if let hint = usernameHint {
                        Text(hint)
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.danger)
                            .padding(.horizontal, 4)
                    }
                }

                // Email + Google verification (§12.2).
                AccountEmailCard()

                aboutCard
                linksCard

                if let error {
                    Text(error).font(KlicFont.caption()).foregroundStyle(.red)
                }

                PillButton(title: saving ? String(localized: "Saving…") : String(localized: "Save")) { Task { await save() } }
                    .disabled(saving || !canSave)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            displayName = session.currentUser?.displayName ?? ""
            username = session.currentUser?.username ?? ""
            about = session.currentUser?.about
            links = session.currentUser?.links ?? []
        }
        .task {
            // Reconcile with the server — about/links may have changed elsewhere.
            if let fresh = try? await APIClient.shared.me() {
                session.updateCurrentUser(fresh)
                about = fresh.about
                links = fresh.links ?? []
                if displayName.isEmpty { displayName = fresh.displayName }
                if username.isEmpty { username = fresh.username }
            }
        }
        .onChange(of: pickedItem) { _, item in Task { await loadPicked(item) } }
        // §11.5: pinch/drag adjust inside a circular mask before the upload.
        .fullScreenCover(item: adjustBinding) { box in
            KlicImageAdjustSheet(image: box.image, mask: .circle) { cropped in
                pickedImage = cropped
            }
        }
        .klicSelectionSheet(
            isPresented: $showAboutSheet,
            title: String(localized: "About"),
            message: String(localized: "Shown on your profile."),
            options: aboutOptions,
            selectedId: aboutSelectedId
        ) { option in
            switch option.id {
            case "custom":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showCustomAbout = true }
            case "none":
                Task { await saveAbout(nil) }
            default:
                Task { await saveAbout(option.label) }
            }
        }
        .sheet(isPresented: $showCustomAbout) {
            AboutCustomSheet(initial: about ?? "") { text in
                Task { await saveAbout(text.isEmpty ? nil : text) }
            }
        }
        .sheet(item: $linkEditor) { target in
            LinkEntrySheet(initial: target.initial) { url in
                Task { await saveLink(url, at: target.index) }
            }
        }
        .klicSelectionSheet(
            isPresented: Binding(
                get: { linkActionIndex != nil },
                set: { if !$0 { linkActionIndex = nil } }
            ),
            title: linkActionIndex.flatMap { links.indices.contains($0) ? links[$0] : nil } ?? String(localized: "Link"),
            options: [
                KlicSheetOption(id: "edit", label: String(localized: "Edit link")),
                KlicSheetOption(id: "remove", label: String(localized: "Remove link"), isDestructive: true),
            ]
        ) { option in
            guard let index = linkActionIndex, links.indices.contains(index) else { return }
            linkActionIndex = nil
            switch option.id {
            case "edit":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    linkEditor = LinkEditorTarget(index: index, initial: links[index])
                }
            case "remove":
                Task { await removeLink(at: index) }
            default:
                break
            }
        }
        .enableInjection()
    }

    // MARK: About card (§11.5)

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(KlicFont.caption())
                .foregroundStyle(KlicColor.textMuted)
            Button { showAboutSheet = true } label: {
                HStack {
                    Text(about?.isEmpty == false ? about! : String(localized: "Add a few words about yourself"))
                        .font(KlicFont.body())
                        .foregroundStyle(about?.isEmpty == false ? KlicColor.textPrimary : KlicColor.textMuted)
                        .lineLimit(1)
                    Spacer()
                    if savingAbout {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(KlicColor.surfaceRaised, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(savingAbout)
        }
    }

    private var aboutOptions: [KlicSheetOption] {
        var options = Self.aboutPresets.map { KlicSheetOption(id: $0, label: $0) }
        options.append(KlicSheetOption(id: "custom", label: String(localized: "Custom…")))
        if about?.isEmpty == false {
            options.append(KlicSheetOption(id: "none", label: String(localized: "Clear About"), isDestructive: true))
        }
        return options
    }

    private var aboutSelectedId: String? {
        guard let about, Self.aboutPresets.contains(about) else {
            return about?.isEmpty == false ? "custom" : nil
        }
        return about
    }

    private func saveAbout(_ value: String?) async {
        savingAbout = true
        defer { savingAbout = false }
        error = nil
        do {
            let user = try await APIClient.shared.updateMe(["about": value ?? NSNull()])
            session.updateCurrentUser(user)
            about = user.about
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = String(localized: "Couldn't save. Please try again.")
        }
    }

    // MARK: Links card (§11.5)

    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Links")
                .font(KlicFont.caption())
                .foregroundStyle(KlicColor.textMuted)
            VStack(spacing: 0) {
                ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                    Button { linkActionIndex = index } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "link")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(KlicColor.primary)
                            Text(link)
                                .font(KlicFont.body(14))
                                .foregroundStyle(KlicColor.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
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
                    Divider().padding(.leading, 44).opacity(0.4)
                }

                if links.count < 5 {
                    Button { linkEditor = LinkEditorTarget(index: nil, initial: "") } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(KlicColor.primary)
                            Text("Add link")
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.primary)
                            Spacer()
                            if savingLinks { ProgressView().controlSize(.small) }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(savingLinks)
                } else {
                    Text("Up to 5 links.")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
            }
            .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func saveLink(_ url: String, at index: Int?) async {
        var updated = links
        if let index, updated.indices.contains(index) {
            updated[index] = url
        } else {
            updated.append(url)
        }
        await pushLinks(updated)
    }

    private func removeLink(at index: Int) async {
        guard links.indices.contains(index) else { return }
        var updated = links
        updated.remove(at: index)
        await pushLinks(updated)
    }

    private func pushLinks(_ updated: [String]) async {
        savingLinks = true
        defer { savingLinks = false }
        error = nil
        do {
            let user = try await APIClient.shared.updateMe(["links": updated])
            session.updateCurrentUser(user)
            links = user.links ?? updated
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = String(localized: "Couldn't save. Please try again.")
        }
    }

    // MARK: Username validation (§11.4)

    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespaces) }

    private var usernameValid: Bool {
        let name = trimmedUsername
        guard name.range(of: Self.usernamePattern, options: .regularExpression) != nil else { return false }
        return !name.hasPrefix(".") && !name.hasSuffix(".")
    }

    private var usernameHint: String? {
        let name = trimmedUsername
        guard !name.isEmpty, name != session.currentUser?.username else { return nil }
        if name.count < 3 { return String(localized: "Usernames have at least 3 characters.") }
        if !usernameValid { return String(localized: "Use lowercase letters, numbers, _ and . (no leading or trailing dot).") }
        return nil
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty && usernameValid
    }

    // MARK: Save

    private var adjustBinding: Binding<AdjustBox?> {
        Binding(
            get: { adjustingImage.map(AdjustBox.init) },
            set: { adjustingImage = $0?.image }
        )
    }

    private struct AdjustBox: Identifiable {
        let image: UIImage
        var id: ObjectIdentifier { ObjectIdentifier(image) }
    }

    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else { return }
        adjustingImage = img
        // Reset so re-picking the same photo fires onChange again.
        pickedItem = nil
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil
        do {
            var uploadedKey: String?
            if let pickedImage, let (data, _, _) = Media.encodeImage(pickedImage) {
                let ticket = try await APIClient.shared.requestAvatarUpload(
                    contentType: "image/jpeg", byteSize: data.count)
                try await APIClient.shared.uploadData(data, to: ticket.uploadUrl, contentType: "image/jpeg")
                uploadedKey = ticket.key
            }
            var fields: [String: Any] = ["displayName": displayName.trimmingCharacters(in: .whitespaces)]
            if let uploadedKey { fields["avatarKey"] = uploadedKey }
            // §11.4: only send the username when it actually changed.
            if trimmedUsername != session.currentUser?.username { fields["username"] = trimmedUsername }
            let user = try await APIClient.shared.updateMe(fields)
            session.updateCurrentUser(user)
            dismiss()
        } catch let e as APIError {
            // Surfaces the server's "Username is taken" verbatim (§11.4).
            self.error = e.userMessage
        } catch {
            self.error = String(localized: "Couldn't save. Please try again.")
        }
    }
}

// MARK: - Custom About entry (§11.5)

private struct AboutCustomSheet: View {
    let initial: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("About")
                .font(KlicFont.headline(16))
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.top, 22)

            TextField(String(localized: "Say something about yourself"), text: $text, axis: .vertical)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
                .tint(KlicColor.primary)
                .lineLimit(3, reservesSpace: true)
                .focused($focused)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16)
                .onChange(of: text) { _, value in
                    if value.count > 140 { text = String(value.prefix(140)) }
                }

            Text(verbatim: "\(text.count)/140")
                .font(KlicFont.caption(12))
                .foregroundStyle(KlicColor.textMuted)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 20)

            PillButton(title: String(localized: "Save")) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                dismiss()
                onSave(trimmed)
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .onAppear {
            text = initial
            focused = true
        }
    }
}

// MARK: - Link entry (§11.5)

private struct LinkEntrySheet: View {
    let initial: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var normalized: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return "https://" + trimmed
    }

    /// http/https URL with a real host, ≤200 chars (§11.5 contract limits).
    private var isValid: Bool {
        let candidate = normalized
        guard !candidate.isEmpty, candidate.count <= 200,
              let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") else { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(initial.isEmpty ? String(localized: "Add link") : String(localized: "Edit link"))
                .font(KlicFont.headline(16))
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.top, 22)

            TextField(String("https://example.com"), text: $text)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
                .tint(KlicColor.primary)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(KlicColor.surface, in: Capsule())
                .padding(.horizontal, 16)

            if !text.isEmpty && !isValid {
                Text("Enter a valid http(s) link.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.danger)
            }

            PillButton(title: String(localized: "Save")) {
                let value = normalized
                dismiss()
                onSave(value)
            }
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.4)
            .padding(.horizontal, 16)
            Spacer()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .onAppear {
            text = initial
            focused = true
        }
    }
}

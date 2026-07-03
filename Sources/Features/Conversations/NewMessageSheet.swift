import SwiftUI
import PhotosUI
import Contacts
import Inject

private enum NewMessageRoute: Hashable {
    case newGroup
    case newGroupDetails([String])
    case newContact
}

struct NewMessageSheet: View {
    @ObserveInjection var inject
    var onOpenChat: ((Conversation) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var path: [NewMessageRoute] = []
    @State private var searchText = ""
    @State private var friends: [User] = []
    @State private var contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var showContactsBanner = true

    private var filtered: [User] {
        guard !searchText.isEmpty else { return friends }
        let q = searchText.lowercased()
        return friends.filter {
            $0.displayName.lowercased().contains(q) || $0.username.lowercased().contains(q)
        }
    }

    private var sections: [(letter: String, users: [User])] {
        let grouped = Dictionary(grouping: filtered) {
            String($0.displayName.prefix(1).uppercased())
        }
        return grouped.keys.sorted().map { letter in
            (letter, grouped[letter]!.sorted { $0.displayName < $1.displayName })
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                searchBar
                Divider().opacity(0.4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        if showContactsBanner && contactsStatus != .authorized {
                            contactsBanner
                            Divider().opacity(0.4)
                        }

                        if searchText.isEmpty {
                            actionRow(icon: .user, title: String(localized: "New Group"), style: .line) {
                                path.append(.newGroup)
                            }
                            Divider().padding(.leading, 82).opacity(0.4)
                            actionRow(icon: .addUser, title: String(localized: "New Contact"), style: .line) {
                                path.append(.newContact)
                            }
                            Divider().opacity(0.4)

                            // "Frequent" row (§10.4): most-messaged friends, computed
                            // locally, gated by the Suggest Frequent Contacts pref.
                            let frequent = FrequentContacts.topFriends(from: friends)
                            if !frequent.isEmpty {
                                sectionHeader(String(localized: "Frequent"))
                                ForEach(Array(frequent.enumerated()), id: \.element.id) { idx, friend in
                                    friendRow(friend)
                                    if idx < frequent.count - 1 {
                                        Divider().padding(.leading, 82).opacity(0.4)
                                    }
                                }
                                Divider().opacity(0.4)
                            }
                        }

                        ForEach(sections, id: \.letter) { section in
                            sectionHeader(section.letter)
                            ForEach(Array(section.users.enumerated()), id: \.element.id) { idx, friend in
                                friendRow(friend)
                                if idx < section.users.count - 1 {
                                    Divider().padding(.leading, 82).opacity(0.4)
                                }
                            }
                        }
                    }
                }
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(KlicColor.textPrimary)
                    }
                }
            }
            .navigationDestination(for: NewMessageRoute.self) { route in
                switch route {
                case .newGroup:
                    NewGroupPickerView(path: $path)
                case .newGroupDetails(let ids):
                    NewGroupDetailsView(selectedIds: ids, onCreated: { dismiss() })
                case .newContact:
                    NewContactView()
                }
            }
        }
        .tint(KlicColor.primary)
        .task { await load() }
        .enableInjection()
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(KlicColor.textMuted)
            TextField("Search", text: $searchText)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
                .tint(KlicColor.primary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(KlicColor.surface, in: Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: Contacts banner

    private var contactsBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(KlicColor.danger)
                Text("Access to Contacts")
                    .font(KlicFont.medium())
                    .foregroundStyle(KlicColor.textPrimary)
                Spacer()
                Button { showContactsBanner = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            Text("Please allow Klic access to your phonebook to seamlessly find all your friends.")
                .font(KlicFont.body(14))
                .foregroundStyle(KlicColor.textMuted)
            Button("Allow in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(KlicFont.medium(14))
            .foregroundStyle(KlicColor.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Action rows

    private func actionRow(icon: KlicIcon, title: String, style: IconStyle = .line, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Icon(icon, size: 22, color: KlicColor.primary, style: style)
                    .frame(width: 48, height: 48)
                    .background(Color(.systemGray5), in: Circle())
                Text(title)
                    .font(KlicFont.medium())
                    .foregroundStyle(KlicColor.primary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Section + friend rows

    private func sectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(KlicFont.caption(12))
            .foregroundStyle(KlicColor.textMuted)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func friendRow(_ friend: User) -> some View {
        Button {
            Task { await openChat(with: friend) }
        } label: {
            HStack(spacing: 14) {
                AvatarView(url: friend.avatarUrl, name: friend.displayName, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName)
                        .font(KlicFont.medium())
                        .foregroundStyle(KlicColor.textPrimary)
                    Text("@\(friend.username)")
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func load() async {
        friends = (try? await APIClient.shared.friends()) ?? []
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    private func openChat(with friend: User) async {
        guard let convo = try? await APIClient.shared.openConversation(userId: friend.id) else { return }
        dismiss()
        onOpenChat?(convo)
    }
}

// MARK: - New Group: Step 1 — Friend picker

private struct NewGroupPickerView: View {
    @ObserveInjection var inject
    @Binding var path: [NewMessageRoute]
    @State private var friends: [User] = []
    @State private var selectedIds: Set<String> = []

    private let maxParticipants = 2_000_000

    var body: some View {
        VStack(spacing: 0) {
            List {
                // "Frequent" row atop the group-create picker (§10.4).
                let frequent = FrequentContacts.topFriends(from: friends)
                if !frequent.isEmpty {
                    Section {
                        ForEach(frequent) { friend in
                            pickerRow(friend)
                        }
                    } header: {
                        Text("Frequent")
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                }
                ForEach(friends) { friend in
                    Button { toggle(friend.id) } label: {
                        HStack(spacing: 14) {
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
                                .font(.system(size: 22))
                                .foregroundStyle(selectedIds.contains(friend.id) ? KlicColor.primary : KlicColor.textMuted)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(KlicColor.background)
                }
            }
            .listStyle(.plain)
            .background(KlicColor.background)
            .scrollContentBackground(.hidden)

            Divider().opacity(0.4)
            PillButton(title: String(localized: "Next")) {
                path.append(.newGroupDetails(Array(selectedIds)))
            }
            .opacity(selectedIds.isEmpty ? 0.4 : 1)
            .disabled(selectedIds.isEmpty)
            .padding(20)
            .background(KlicColor.background)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("New Group")
                        .font(KlicFont.headline())
                        .foregroundStyle(KlicColor.textPrimary)
                    Text("\(selectedIds.count) / \(maxParticipants.formatted()) participants")
                        .font(.system(size: 11))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
        }
        .task { friends = (try? await APIClient.shared.friends()) ?? [] }
        .enableInjection()
    }

    private func toggle(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private func pickerRow(_ friend: User) -> some View {
        Button { toggle(friend.id) } label: {
            HStack(spacing: 14) {
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
                    .font(.system(size: 22))
                    .foregroundStyle(selectedIds.contains(friend.id) ? KlicColor.primary : KlicColor.textMuted)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(KlicColor.background)
    }
}

// MARK: - New Group: Step 2 — Name + photo

private struct NewGroupDetailsView: View {
    @ObserveInjection var inject
    let selectedIds: [String]
    let onCreated: () -> Void

    @State private var groupName = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var groupImage: UIImage?
    /// §11.5: raw pick → adjust step (rounded-square mask) → groupImage.
    @State private var adjustingImage: UIImage?
    @State private var showPhotoOptions = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Button { showPhotoOptions = true } label: {
                    ZStack(alignment: .bottomTrailing) {
                        if let groupImage {
                            Image(uiImage: groupImage)
                                .resizable().scaledToFill()
                                .frame(width: 100, height: 100)
                                .clipShape(Circle())
                        } else {
                            AvatarView(url: nil, name: groupName.isEmpty ? "G" : groupName, size: 100)
                        }
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KlicColor.onPrimary)
                            .frame(width: 34, height: 34)
                            .background(KlicColor.primary, in: Circle())
                            .overlay(Circle().stroke(KlicColor.background, lineWidth: 3))
                    }
                }
                .padding(.top, 8)

                KlicTextField(placeholder: String(localized: "Group Name"), text: $groupName)

                if let error {
                    Text(error).font(KlicFont.caption()).foregroundStyle(KlicColor.danger)
                }

                PillButton(title: isCreating ? "Creating…" : "Create") {
                    Task { await createGroup() }
                }
                .opacity(groupName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating ? 0.4 : 1)
                .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Choose Photo", isPresented: $showPhotoOptions, titleVisibility: .visible) {
            Button("Camera") { showCamera = true }
            Button("Photo Library") { showPhotoPicker = true }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) { CameraPickerView(image: $groupImage) }
        .onChange(of: pickedItem) { _, item in
            Task {
                guard let item,
                      let data = try? await item.loadTransferable(type: Data.self),
                      let img = UIImage(data: data) else { return }
                adjustingImage = img
                pickedItem = nil
            }
        }
        // §11.5: adjust inside a rounded-square mask before the cover is used.
        .fullScreenCover(item: Binding(
            get: { adjustingImage.map(GroupCoverAdjustBox.init) },
            set: { adjustingImage = $0?.image }
        )) { box in
            KlicImageAdjustSheet(image: box.image, mask: .roundedSquare) { cropped in
                groupImage = cropped
            }
        }
        .enableInjection()
    }

    private func createGroup() async {
        let title = groupName.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let convo = try await APIClient.shared.createGroupConversation(title: title, userIds: selectedIds)
            if let img = groupImage, let (data, _, _) = Media.encodeImage(img) {
                let ticket = try await APIClient.shared.requestGroupAvatarUpload(
                    conversationId: convo.id, contentType: "image/jpeg", byteSize: data.count)
                try await APIClient.shared.uploadData(data, to: ticket.uploadUrl, contentType: "image/jpeg")
                _ = try? await APIClient.shared.updateGroupConversation(id: convo.id, avatarKey: ticket.key)
            }
            onCreated()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn't create group. Try again."
        }
    }
}

// MARK: - New Contact

private struct NewContactView: View {
    @ObserveInjection var inject
    @State private var username = ""
    @State private var statusText: String?
    @State private var isSending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    KlicTextField(placeholder: String(localized: "username"), text: $username)
                    Button { Task { await sendRequest() } } label: {
                        if isSending {
                            ProgressView()
                                .frame(width: 50, height: 50)
                                .background(KlicColor.primary, in: Circle())
                        } else {
                            Icon(.addUser, size: 22, color: KlicColor.onPrimary)
                                .frame(width: 50, height: 50)
                                .background(KlicColor.primary, in: Circle())
                        }
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                }
                if let statusText {
                    Text(statusText).font(KlicFont.caption()).foregroundStyle(KlicColor.textMuted)
                }
                Spacer()
            }
            .padding(24)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("New Contact")
        .navigationBarTitleDisplayMode(.inline)
        .enableInjection()
    }

    private func sendRequest() async {
        let name = username.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        guard let users = try? await APIClient.shared.findUser(username: name), let target = users.first else {
            statusText = "No user named \"\(name)\"."
            return
        }
        _ = try? await APIClient.shared.sendFriendRequest(userId: target.id)
        statusText = "Request sent to \(target.displayName)."
        username = ""
    }
}

// MARK: - Camera picker

private struct CameraPickerView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView
        init(_ parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Identifiable wrapper so the §11.5 adjust step can present from an optional UIImage.
private struct GroupCoverAdjustBox: Identifiable {
    let image: UIImage
    var id: ObjectIdentifier { ObjectIdentifier(image) }
}

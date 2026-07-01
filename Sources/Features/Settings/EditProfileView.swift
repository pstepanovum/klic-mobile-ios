import SwiftUI
import PhotosUI
import Inject

/// Edit the current user's profile photo and display name. Username is immutable.
struct EditProfileView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var saving = false
    @State private var error: String?

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
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
                    if let user = session.currentUser {
                        Text("@\(user.username)")
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.textMuted)
                            .padding(.horizontal, 4)
                    }
                }

                if let error {
                    Text(error).font(KlicFont.caption()).foregroundStyle(.red)
                }

                PillButton(title: saving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(saving || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { displayName = session.currentUser?.displayName ?? "" }
        .onChange(of: pickedItem) { _, item in Task { await loadPicked(item) } }
        .enableInjection()
    }

    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else { return }
        pickedImage = img
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
            let name = displayName.trimmingCharacters(in: .whitespaces)
            let user: User
            if let uploadedKey {
                user = try await APIClient.shared.updateProfile(displayName: name, avatarKey: uploadedKey)
            } else {
                user = try await APIClient.shared.updateProfile(displayName: name)
            }
            session.updateCurrentUser(user)
            dismiss()
        } catch let e as APIError {
            self.error = e.userMessage
        } catch {
            self.error = "Couldn't save. Please try again."
        }
    }
}

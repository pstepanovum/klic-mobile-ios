import SwiftUI

/// One row in a `KlicSelectionSheet`.
struct KlicSheetOption: Identifiable {
    let id: String
    let label: String
    var subtitle: String? = nil
    var isDestructive: Bool = false
}

/// The one Klic bottom-sheet selector (CALLS.md §9.2): rounded container, option rows
/// with a check on the selected row, and a full-width cancel pill. Replaces every
/// native Menu / Picker / confirmationDialog option picker in the app.
struct KlicSelectionSheet: View {
    let title: String
    var message: String? = nil
    let options: [KlicSheetOption]
    var selectedId: String? = nil
    /// Pickers dismiss on tap; preview-style sheets (tones) stay open so the user
    /// can listen before leaving.
    var dismissOnSelect: Bool = true
    let onSelect: (KlicSheetOption) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(title)
                    .font(KlicFont.headline(16))
                    .foregroundStyle(KlicColor.textPrimary)
                if let message {
                    Text(message)
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 24)

            optionList

            PillButton(title: "Cancel", fill: KlicColor.surfaceRaised, textColor: KlicColor.textMuted) {
                dismiss()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .presentationDetents([.height(estimatedHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(KlicColor.background)
    }

    @ViewBuilder private var optionList: some View {
        let rows = VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                optionRow(option)
                if index < options.count - 1 {
                    Divider().padding(.leading, 20).opacity(0.4)
                }
            }
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)

        if options.count > 7 {
            ScrollView { rows }
        } else {
            rows
        }
    }

    private func optionRow(_ option: KlicSheetOption) -> some View {
        Button {
            onSelect(option)
            if dismissOnSelect { dismiss() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(KlicFont.body())
                        .foregroundStyle(option.isDestructive ? KlicColor.danger : KlicColor.textPrimary)
                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                }
                Spacer()
                if selectedId == option.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(KlicColor.primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, option.subtitle == nil ? 14 : 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var estimatedHeight: CGFloat {
        let rows = options.reduce(CGFloat(0)) { $0 + ($1.subtitle == nil ? 50 : 60) }
        let header: CGFloat = message == nil ? 52 : 88
        let cancel: CGFloat = 80
        return min(header + rows + cancel + 24, 600)
    }
}

extension View {
    /// Presents the shared Klic option sheet (§9.2). `dismissOnSelect: false` keeps the
    /// sheet up after a tap (used by the tone pickers so previews can be auditioned);
    /// `onDismiss` runs on any close and is where preview playback must stop (§9.4).
    func klicSelectionSheet(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        options: [KlicSheetOption],
        selectedId: String? = nil,
        dismissOnSelect: Bool = true,
        onDismiss: (() -> Void)? = nil,
        onSelect: @escaping (KlicSheetOption) -> Void
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            KlicSelectionSheet(
                title: title,
                message: message,
                options: options,
                selectedId: selectedId,
                dismissOnSelect: dismissOnSelect,
                onSelect: onSelect
            )
        }
    }
}

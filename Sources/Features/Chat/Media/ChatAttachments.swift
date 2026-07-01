import SwiftUI

struct MessageAttachmentsView: View {
    let attachments: [Attachment]
    let isMine: Bool
    var showTime: Bool = false
    var time: String = ""
    var status: String? = nil
    var onOpenAttachment: (Attachment) -> Void = { _ in }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            ForEach(Array(attachments.enumerated()), id: \.1.id) { index, attachment in
                let isLastAttachment = showTime && index == attachments.count - 1
                switch attachment.kind {
                case "IMAGE":
                    ImageAttachmentView(
                        attachment: attachment,
                        isMine: isMine,
                        time: isLastAttachment ? time : nil,
                        status: isLastAttachment ? status : nil,
                        onOpen: { onOpenAttachment(attachment) }
                    )
                case "VOICE":
                    VoiceAttachmentView(
                        attachment: attachment,
                        isMine: isMine,
                        time: isLastAttachment ? time : nil,
                        status: isLastAttachment ? status : nil
                    )
                case "VIDEO":
                    VideoAttachmentView(
                        attachment: attachment,
                        isMine: isMine,
                        time: isLastAttachment ? time : nil,
                        status: isLastAttachment ? status : nil,
                        onOpen: { onOpenAttachment(attachment) }
                    )
                default:
                    FileAttachmentView(attachment: attachment, isMine: isMine)
                }
            }
        }
    }
}

private struct ImageAttachmentView: View {
    let attachment: Attachment
    let isMine: Bool
    var time: String? = nil
    var status: String? = nil
    let onOpen: () -> Void

    private var size: CGSize {
        let width: CGFloat = 220
        guard let attachmentWidth = attachment.width,
              let attachmentHeight = attachment.height,
              attachmentWidth > 0,
              attachmentHeight > 0 else {
            return CGSize(width: width, height: width)
        }
        let height = min(max(width * CGFloat(attachmentHeight) / CGFloat(attachmentWidth), 120), 320)
        return CGSize(width: width, height: height)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(url: URL(string: attachment.url)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    KlicColor.surfaceRaised.overlay(Image(systemName: "photo").foregroundStyle(KlicColor.textMuted))
                default:
                    KlicColor.surfaceRaised.overlay(LoadingCircle())
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if let time {
                mediaPill(time: time)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: onOpen)
    }

    private func mediaPill(time: String) -> some View {
        HStack(spacing: 3) {
            Text(time)
                .font(KlicFont.caption(11))
                .foregroundStyle(.white)
            if isMine, let status {
                MessageTicks(status: status, onPrimary: true)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(8)
    }
}

private struct VoiceAttachmentView: View {
    let attachment: Attachment
    let isMine: Bool
    var time: String? = nil
    var status: String? = nil

    @ObservedObject private var player = AudioPlaybackManager.shared

    private var playing: Bool { player.playingId == attachment.id }
    private var tint: Color { isMine ? KlicColor.onPrimary : KlicColor.primary }

    private var waveformAmplitudes: [Float] {
        guard let base64 = attachment.waveform, let data = Data(base64Encoded: base64) else { return [] }
        return unpackWaveform(data)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 10) {
                Button { player.toggle(id: attachment.id, url: attachment.url) } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isMine ? KlicColor.primary : KlicColor.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(tint, in: Circle())
                }

                WaveformBarsView(
                    amplitudes: waveformAmplitudes,
                    progress: playing ? player.progress : 0,
                    isOutgoing: isMine
                )
                .frame(width: 110)

                Text(durationText)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.85) : KlicColor.textMuted)
                    .monospacedDigit()
            }

            if let time {
                HStack(spacing: 3) {
                    Text(time)
                        .font(KlicFont.caption(11))
                        .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.65) : KlicColor.textMuted)
                    if isMine, let status {
                        MessageTicks(status: status, onPrimary: isMine)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isMine ? KlicColor.primary : KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
    }

    private var durationText: String {
        let seconds = (attachment.durationMs ?? 0) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VideoAttachmentView: View {
    let attachment: Attachment
    let isMine: Bool
    var time: String? = nil
    var status: String? = nil
    let onOpen: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.85))
            Image(systemName: "play.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.95))

            if let milliseconds = attachment.durationMs, milliseconds > 0 {
                Text(durationText)
                    .font(KlicFont.caption(11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(8)
            }

            if let time {
                HStack(spacing: 3) {
                    Text(time)
                        .font(KlicFont.caption(11))
                        .foregroundStyle(.white)
                    if isMine, let status {
                        MessageTicks(status: status, onPrimary: true)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.45), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
            }
        }
        .frame(width: 220, height: 150)
        .onTapGesture(perform: onOpen)
    }

    private var durationText: String {
        let seconds = (attachment.durationMs ?? 0) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct FileAttachmentView: View {
    let attachment: Attachment
    let isMine: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: attachment.url) {
                openURL(url)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName ?? "File")
                        .font(KlicFont.body())
                        .lineLimit(1)
                        .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.textPrimary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))
                        .font(KlicFont.caption(11))
                        .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.8) : KlicColor.textMuted)
                }
            }
            .padding(12)
            .frame(maxWidth: 240, alignment: .leading)
            .background(isMine ? KlicColor.primary : KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

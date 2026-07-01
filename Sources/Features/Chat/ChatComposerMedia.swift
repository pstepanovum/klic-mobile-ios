import SwiftUI
import UIKit

struct PendingMediaDraft: Identifiable, Equatable {
    let id = UUID()
    let kind: String
    let contentType: String
    let data: Data
    let previewImage: UIImage
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var waveform: Data?
    var fileName: String?
}

struct PendingMediaComposerBar: View {
    let items: [PendingMediaDraft]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: item.previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                        if item.kind == "VIDEO" {
                            Image(systemName: "video.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.6), in: Circle())
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }

                        Button { onRemove(item.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .padding(6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .padding(.bottom, 4)
        .background(KlicColor.background)
    }
}

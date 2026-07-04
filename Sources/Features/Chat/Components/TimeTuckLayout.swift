import SwiftUI
import UIKit

/// §15.2: lays out a text bubble's body + its time/ticks chip with no dead space.
///
/// The old row put the chip beside the whole text block, which reserved a full-height
/// empty band on the trailing side of every multi-line message. This layout instead
/// measures the text's LAST line and:
/// - tucks the chip into the last line's trailing gap when it fits there for free,
/// - otherwise widens only up to what the last line + chip actually need,
/// - and only when even that exceeds the available width does the chip wrap to its
///   own compact trailing row.
/// Either way the bubble hugs the longest text line.
///
/// Expects exactly two children: [0] the message text, [1] the time/ticks chip.
struct TimeTuckLayout: Layout {
    let text: String
    let font: UIFont
    var highlightMentions: Bool = false
    var mentionNames: [String] = []

    /// Breathing room between the last line's end and the chip.
    private static let gap: CGFloat = 8
    /// Vertical spacing when the chip wraps to its own row.
    private static let rowSpacing: CGFloat = 2

    struct Cache {
        var proposedWidth: CGFloat = -1
        var textSize: CGSize = .zero
        var lastLineWidth: CGFloat = 0
        var timeSize: CGSize = .zero
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measure(proposal, subviews: subviews, cache: &cache)
        let text = cache.textSize
        let time = cache.timeSize
        if tucksInline(cache) {
            return CGSize(
                width: max(text.width, cache.lastLineWidth + Self.gap + time.width),
                height: max(text.height, time.height)
            )
        }
        return CGSize(
            width: max(text.width, time.width),
            height: text.height + Self.rowSpacing + time.height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(proposal, subviews: subviews, cache: &cache)
        guard subviews.count == 2 else { return }
        // The text must wrap at the SAME width it was measured against, not at the
        // final bounds width, or the line breaks (and the tucked chip) would shift.
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: cache.proposedWidth, height: nil)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.maxY),
            anchor: .bottomTrailing,
            proposal: .unspecified
        )
    }

    /// The chip shares the last line when last-line + gap + chip stays within the
    /// proposed width — whether inside the longest line's trailing gap (free) or by
    /// nudging the bubble a little wider.
    private func tucksInline(_ cache: Cache) -> Bool {
        cache.lastLineWidth + Self.gap + cache.timeSize.width <= cache.proposedWidth
    }

    private func measure(_ proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        var maxWidth = proposal.width ?? .greatestFiniteMagnitude
        if !maxWidth.isFinite || maxWidth <= 0 { maxWidth = .greatestFiniteMagnitude }
        guard cache.proposedWidth != maxWidth else { return }
        cache.proposedWidth = maxWidth
        cache.timeSize = subviews[1].sizeThatFits(.unspecified)
        cache.textSize = subviews[0].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        cache.lastLineWidth = Self.lastLineWidth(
            text: text,
            font: font,
            highlightMentions: highlightMentions,
            mentionNames: mentionNames,
            wrapWidth: maxWidth
        )
    }

    /// Width of the final rendered line, computed with the same TextKit 1 engine
    /// (and the same attributed runs) the bubble's text view renders with.
    private static func lastLineWidth(
        text: String,
        font: UIFont,
        highlightMentions: Bool,
        mentionNames: [String],
        wrapWidth: CGFloat
    ) -> CGFloat {
        let attributed = RichMessageText.mentionAttributedText(
            text: text, font: font, textColor: .label,
            highlightMentions: highlightMentions, mentionNames: mentionNames,
            mentionColor: .label
        ) ?? NSAttributedString(string: text, attributes: [.font: font])

        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(size: CGSize(width: wrapWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let glyphRange = layoutManager.glyphRange(for: container)
        guard glyphRange.length > 0 else { return 0 }
        let lastLine = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphRange.upperBound - 1, effectiveRange: nil
        )
        return ceil(lastLine.width)
    }
}

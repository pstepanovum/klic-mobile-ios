import SwiftUI

/// TikTok Sans type scale. Files registered via UIAppFonts in Info.plist.
enum KlicFont {
    static func display(_ size: CGFloat = 32) -> Font { .custom("TikTokSans-Black", size: size) }
    static func title(_ size: CGFloat = 22) -> Font { .custom("TikTokSans-Bold", size: size) }
    static func headline(_ size: CGFloat = 17) -> Font { .custom("TikTokSans-SemiBold", size: size) }
    static func body(_ size: CGFloat = 16) -> Font { .custom("TikTokSans-Regular", size: size) }
    static func medium(_ size: CGFloat = 16) -> Font { .custom("TikTokSans-Medium", size: size) }
    static func caption(_ size: CGFloat = 13) -> Font { .custom("TikTokSans-Light", size: size) }
    /// Bangers — a bold display face used for the brand tagline.
    static func banger(_ size: CGFloat = 34) -> Font { .custom("Bangers-Regular", size: size) }

    /// TikTok Sans, 24pt-optical-size Expanded cut — the auth pages' big-title/CTA face
    /// (Welcome "Get Started", Login/Sign Up titles and primary buttons).
    static func expandedMedium(_ size: CGFloat = 17) -> Font { .custom("TikTokSans24ptExpanded-Medium", size: size) }
    static func expandedBold(_ size: CGFloat = 28) -> Font { .custom("TikTokSans24ptExpanded-Bold", size: size) }
    /// Top-level page titles — Chats, Friends, Call, Settings (§13.2).
    static func expandedRegular(_ size: CGFloat = 24) -> Font { .custom("TikTokSans24ptExpanded-Regular", size: size) }
}

import SwiftUI

/// One-off constants for the Login / Sign Up pages — values pulled straight from the
/// Figma mock that don't map onto the shared `KlicColor` palette (that palette stays
/// untouched; these are additive, scoped to the auth flow only).
enum AuthStyle {
    /// Primary CTA red ("Login" / "Sign up" buttons) — distinct from KlicColor.primary/danger.
    static let ctaRed = Color(hex: 0xD90429)
    /// Placeholder / hint text inside the capsule inputs — same value in both themes.
    static let fieldHint = Color(hex: 0xC7C7C7)
    /// Small secondary/link text (passkey row, "Create an account", "I already have
    /// an account", the privacy-policy agreement line) — same value in both themes.
    static let smallText = Color(hex: 0xB2B2B2)
    /// Radius of the big rounded "sheet" the content sits on.
    static let circleRadius: CGFloat = 546
    /// Cap on the auth content column's width so form fields/buttons stay a
    /// readable line length instead of stretching edge-to-edge on iPad.
    static let contentMaxWidth: CGFloat = 500
    /// iPhone width the circle radius / background-art constants were tuned
    /// against; AuthScaffold scales those values by (canvas width / this).
    static let referenceWidth: CGFloat = 390

    static func fieldFill(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x202020) : Color(hex: 0xF2F2F2)
    }

    /// Dark theme reuses the existing surface token (near-black, distinct from the
    /// pure-black background) rather than inventing a new shade.
    static func circleFill(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? KlicColor.surface : Color.white
    }

    static func titleColor(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : Color(hex: 0x111111)
    }
}

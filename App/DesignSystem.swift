import SwiftUI

// Design foundation. Deliberately thin: this app leans on Apple-native components
// and materials, and REUSES the "developer-tool" button/card language already
// confirmed for the sibling SynologyMonitor app (ported here verbatim) so the two
// apps read as one product family — rather than inventing a bespoke system.

/// Shared spacing / radius tokens, so values stop being ad-hoc across views.
enum DS {
    // 4-based spacing scale (grid gaps stay at 2 for a tight photo mosaic).
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24

    // Corner radii.
    static let rThumb: CGFloat = 5     // grid thumbnails
    static let rCard: CGFloat = 10     // inspector / detail cards
    static let rControl: CGFloat = 8   // buttons, pills
    static let rPopover: CGFloat = 12

    static let hairline = Color.primary.opacity(0.08)
}

/// A grouped-content card in the confirmed aesthetic: a genuinely distinct
/// surface (not just a material tint), a fine adaptive hairline, and a soft
/// shadow for subtle elevation.
struct DSCard: ViewModifier {
    var padding: CGFloat = DS.s3
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }
}

extension View {
    func dsCard(padding: CGFloat = DS.s3) -> some View { modifier(DSCard(padding: padding)) }

    /// A floating overlay pill (material fill + fine hairline + soft shadow).
    /// Single source of truth for the timeline scale switcher, year rail, and
    /// notice banner so they read identically.
    func dsFloating() -> some View {
        self
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.hairline))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

// MARK: - Button styles (ported from SynologyMonitor/…/ActionButtonStyles.swift —
//         the Linear/Raycast/Vercel "developer-tool" look the user confirmed:
//         crisp solid fills, a 1px top-lit hairline, small radius, no glass.)

struct PrimaryActionButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rControl, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small content-hugging pill for chips/toggles (capsule, hairline language).
struct ChipButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(tint.opacity(configuration.isPressed ? 0.18 : 0.10))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

import SwiftUI
import AppKit

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

    // Corner radii (macOS 26 Tahoe direction — see the design handoff).
    static let rThumb: CGFloat = 7      // grid thumbnails
    static let rRow: CGFloat = 9        // sidebar rows, small secondary buttons
    static let rCard: CGFloat = 14      // inspector / detail cards, settings groups
    static let rPopover: CGFloat = 18   // popovers
    static let rBar: CGFloat = 22       // floating chrome bar, notice banner
    static let rControl: CGFloat = 99   // buttons, chips, segments — capsules now

    static let hairline = Color.primary.opacity(0.08)

    // MARK: - Neutrals (warm axis, hue ~80)
    //
    // Every token here defines BOTH vintages. A colour with only one is the
    // classic unreadable-in-the-other-theme bug: `Color(light:dark:)` makes
    // forgetting impossible by construction.

    /// Content ground — the surface photos sit on.
    static let content = Color(light: 0xFCFBF8, dark: 0x1F1E1B)
    /// Sidebar.
    static let sidebar = Color(light: 0xF0EEE9, dark: 0x1A1917)
    /// Toolbars, section headers, commit bars.
    static let bar = Color(light: 0xF6F4F1, dark: 0x23221F)
    /// Raised card surface.
    static let card = Color(light: 0xFFFFFF, dark: 0x2E2C29)

    // MARK: - Status
    static let ok = Color(light: 0x2E8C63, dark: 0x6FD3A4)
    static let danger = Color(light: 0xC0453C, dark: 0xF08279)
    static let warn = Color(light: 0xC77A2A, dark: 0xE0A054)
    static let star = Color(light: 0xD9A21B, dark: 0xEFC24A)
    /// Settings row badges are held to THREE meanings: accent = 내 데이터,
    /// this grey = 시스템·진단, warn = 주의가 필요한 항목. The old palette ran
    /// to seven hues with no rule behind which row got which.
    static let systemGray = Color(light: 0x9A968F, dark: 0x7E7A73)
}

extension Color {
    /// A token with both vintages, resolved by the view's appearance.
    ///
    /// Hex is written the way the handoff writes it, so a value can be checked
    /// against the design doc without converting anything by hand.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

/// A grouped-content card in the confirmed aesthetic: a genuinely distinct
/// surface (not just a material tint), a fine adaptive hairline, and a soft
/// shadow for subtle elevation.
struct DSCard: ViewModifier {
    var padding: CGFloat = DS.s3
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(DS.card,
                        in: RoundedRectangle(cornerRadius: DS.rCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.rCard, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }
}

extension View {
    func dsCard(padding: CGFloat = DS.s3) -> some View { modifier(DSCard(padding: padding)) }

    /// A floating overlay pill. Single source of truth for the timeline scale
    /// switcher, year rail, and notice banner so they read identically.
    ///
    /// `.ultraThinMaterial` rather than `.regularMaterial`, plus a 1px lit top
    /// edge: the glass should let the photos through and catch light along its
    /// rim, not sit on them as a grey slab.
    func dsFloating() -> some View {
        self
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.45), DS.hairline],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
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
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
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
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
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

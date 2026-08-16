//
//  Style.swift
//  MicromsgiOS
//
//  Micromsg Visual System v2 — single source of truth for colors, typography, spacing, icons, layout, animation.
//

import SwiftUI
import UIKit

enum Style {

    // MARK: - Colors ("Greige & Azure" system, dynamic light/dark)

    // Warm near-neutral surfaces; ink is the action color (black pill in
    // light, bone in dark); azure is spent exactly once per screen on links;
    // amber/pink counters are the only other color. Every token resolves per
    // color scheme so the static API works unchanged in all views.
    enum Color {
        private static func dynamic(light: String, dark: String) -> SwiftUI.Color {
            SwiftUI.Color(UIColor { trait in
                trait.userInterfaceStyle == .light
                    ? UIColor(hex: light)
                    : UIColor(hex: dark)
            })
        }

        /// Background (app)
        static let background = dynamic(light: "F4F3F0", dark: "111112")
        /// Primary text (entries + header title)
        static let primaryText = dynamic(light: "161718", dark: "F0EFEC")
        /// Secondary/meta text, icon/meta tint, composer placeholder, composer mic idle
        static let secondary = dynamic(light: "8B8A86", dark: "84837F")
        /// Separator/divider
        static let separator = dynamic(light: "E7E5E1", dark: "232324")
        /// Composer background
        static let composerBackground = dynamic(light: "FFFFFF", dark: "1A1A1B")
        /// Composer send / primary action fill — ink in light, bone in dark
        static let composerSend = dynamic(light: "161718", dark: "F0EFEC")
        /// Glyph/label on top of a composerSend fill
        static let composerSendForeground = dynamic(light: "FFFFFF", dark: "111112")
        /// Link-card title text + link glyph tint — the single azure moment per screen
        static let linkAccent = SwiftUI.Color(hex: "2AA2FF")
        /// Destructive actions (e.g. delete)
        static let destructive = dynamic(light: "C42B44", dark: "FF6478")
        /// Resurface indicator
        static let resurface = dynamic(light: "D9822B", dark: "F0A868")
        /// Fire indicator
        static let fire = dynamic(light: "E36D9A", dark: "F49CC0")

        // UIKit-facing dynamics for the UITextView-backed editors.
        static let primaryTextUIColor = UIColor { trait in
            trait.userInterfaceStyle == .light
                ? UIColor(hex: "161718")
                : UIColor(hex: "F0EFEC")
        }
        static let composerSendUIColor = UIColor { trait in
            trait.userInterfaceStyle == .light
                ? UIColor(hex: "161718")
                : UIColor(hex: "F0EFEC")
        }
    }

    // MARK: - Typography

    enum Typography {
        /// Header title "kebab": JetBrains Mono NL, bold, 18pt, 24pt line height
        static func headerTitle() -> Font {
            .custom("JetBrainsMonoNL-Bold", size: 18)
        }
        /// Entry body: DM Sans regular, 16pt, 24pt line height
        static func body() -> Font {
            .custom("DMSans-Regular", size: 16)
        }
        /// Timestamp/overline, reply count: DM Sans regular, 14pt, 24pt line height, use secondary color
        static func meta() -> Font {
            .custom("DMSans-Regular", size: 14)
        }
        /// Composer placeholder: DM Sans medium, 16pt, 24pt line height, use secondary color
        static func composerPlaceholder() -> Font {
            .custom("DMSans-Medium", size: 16)
        }
        /// Composer active text: DM Sans regular, 16pt, 24pt line height, use primary color
        static func composerText() -> Font {
            .custom("DMSans-Regular", size: 16)
        }
        /// Link card text: DM Sans medium, 14pt, underlined, use primary color
        static func linkCard() -> Font {
            .custom("DMSans-Medium", size: 14)
        }
        /// Auth screen titles: DM Sans extra bold, 24pt, 32pt line height
        static func authTitle() -> Font {
            .custom("DMSans-ExtraBold", size: 24)
        }
        /// Auth button labels: DM Sans semibold, 16pt, 24pt line height
        static func authButton() -> Font {
            .custom("DMSans-SemiBold", size: 16)
        }
        /// Empty state title: DM Sans extra bold, 16pt, 24pt line height
        static func emptyStateTitle() -> Font {
            .custom("DMSans-ExtraBold", size: 16)
        }
        /// Pill/chip label — the app-wide selected-pill rule: a modest weight
        /// bump on selection (medium vs regular), same 14pt size. Used by the
        /// feed's sub-collection chips and Search's collection-filter pills.
        static func pill(selected: Bool) -> Font {
            selected ? .custom("DMSans-Medium", size: 14) : meta()
        }

        static let bodyLineHeight: CGFloat = 24
        static let metaLineHeight: CGFloat = 24

        struct BodyTextModifier: ViewModifier {
            func body(content: Content) -> some View {
                content
                    .font(Typography.body())
                    .lineSpacing(Typography.bodyLineHeight - 16)
            }
        }

        struct MetaTextModifier: ViewModifier {
            func body(content: Content) -> some View {
                content
                    .font(Typography.meta())
                    .lineSpacing(Typography.metaLineHeight - 14)
            }
        }

        static func bodyText() -> BodyTextModifier {
            BodyTextModifier()
        }

        static func metaText() -> MetaTextModifier {
            MetaTextModifier()
        }
    }

    // MARK: - Spacing (base unit 4pt)

    enum Spacing {
        static let base: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        /// Timestamp row above body
        static let timestampAboveBody: CGFloat = base
        /// Reply icon row below body
        static let replyBelowBody: CGFloat = x3
        /// Reply count below reply icon row
        static let replyCountBelowIcon: CGFloat = x2
        /// Composer inner padding vertical
        static let composerPaddingVertical: CGFloat = x3
        /// Composer inner padding left
        static let composerPaddingLeft: CGFloat = x4
        /// Composer text right margin from action button
        static let composerTextMarginRight: CGFloat = x3
        /// Composer action button inset from edges
        static let composerButtonInset: CGFloat = 6
        /// Empty state container margin (all four sides)
        static let emptyStateMargin: CGFloat = 24
    }

    // MARK: - Icon

    enum Icon {
        /// Standard icon grid used throughout the app
        static let grid: CGFloat = 24
        /// Default glyph size inside the grid
        static let glyph: CGFloat = 21
        /// Smaller glyph used for optical balance (ellipsis etc)
        static let glyphSmall: CGFloat = 16
    }

    // MARK: - Layout

    enum Layout {
        /// Entry content padding on all sides
        static let entryContentPadding: CGFloat = 16
        /// Single-line composer height
        static let composerSingleLineHeight: CGFloat = 48
        /// Multi-line composer max height = 40% of available (computed in view)
        static let composerMaxHeightFraction: CGFloat = 0.40
        /// Action button (mic/send) size
        static let actionButtonSize: CGFloat = 36
        /// Capsule radius when single-line (height/2)
        static var composerCapsuleRadius: CGFloat { composerSingleLineHeight / 2 }
        /// Constant bottom reserve the feed keeps for the floating composer.
        /// Deliberately fixed: composer growth, focus, the quick-action strip,
        /// and the keyboard must never change the feed's scroll insets.
        static let feedBottomReserve: CGFloat = composerSingleLineHeight
        /// Multi-line composer corner radius
        static let composerMultiLineRadius: CGFloat = 24
        /// Link card height
        static let linkCardHeight: CGFloat = 44
        /// Link card corner radius (compact / icon-only variants)
        static let linkCardCornerRadius: CGFloat = 12
        /// Link card corner radius for previews that include a thumbnail
        /// image — the large surface earns a softer corner.
        static let linkCardThumbnailCornerRadius: CGFloat = linkCardCornerRadius + 4

        /// Header offset from the physical top of the screen — the same
        /// 60pt used by the Search and Settings headers.
        static let authHeaderTopOffset: CGFloat = 60
    }

    // MARK: - Animation

    enum Animation {
        /// Mic ↔ send transition: no spring, easeInOut 0.2–0.25s
        static let composerStateDuration: Double = 0.22
        static var composerState: SwiftUI.Animation {
            .easeInOut(duration: composerStateDuration)
        }
    }

    // MARK: - Timestamp

    enum Timestamp {
        private static let absoluteFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MM/dd/yy • h:mma"
            f.amSymbol = "am"
            f.pmSymbol = "pm"
            return f
        }()

        /// Full absolute string for `date` using the app-standard format.
        /// Use on dedicated detail screens where a static, precise timestamp is preferred.
        static func absolute(for date: Date) -> String {
            absoluteFormatter.string(from: date)
        }

        /// Compact relative string for `date`.
        /// Pass `relativeTo` from a `TimelineView` context for live updates;
        /// defaults to `Date()` for one-shot use.
        ///
        /// - < 1 min  → "right now"
        /// - 1–59 min → "1m" … "59m"
        /// - 1–23 h   → "1h" … "23h"
        /// - ≥ 1 d    → "1d", "2d", … (counts up indefinitely)
        static func relative(for date: Date, relativeTo now: Date = Date()) -> String {
            let age = max(0, now.timeIntervalSince(date))
            switch age {
            case ..<60:
                return "right now"
            case ..<3_600:
                return "\(Int(age / 60))m"
            case ..<86_400:
                return "\(Int(age / 3_600))h"
            default:
                return "\(Int(age / 86_400))d"
            }
        }
    }
}

// MARK: - Color hex initializers

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

extension SwiftUI.Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

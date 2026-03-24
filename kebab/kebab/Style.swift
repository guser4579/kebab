//
//  Style.swift
//  MicromsgiOS
//
//  Micromsg Visual System v2 — single source of truth for colors, typography, spacing, icons, layout, animation.
//

import SwiftUI

enum Style {

    // MARK: - Colors (exact hex)

    enum Color {
        /// Background (app)
        static let background = SwiftUI.Color(hex: "171718")
        /// Primary text (entries + header title)
        static let primaryText = SwiftUI.Color(hex: "CAD0DB")
        /// Secondary/meta text, icon/meta tint, composer placeholder, composer mic idle
        static let secondary = SwiftUI.Color(hex: "575B61")
        /// Separator/divider
        static let separator = SwiftUI.Color(hex: "262727")
        /// Composer background
        static let composerBackground = SwiftUI.Color(hex: "282828")
        /// Composer send (typing state)
        static let composerSend = SwiftUI.Color(hex: "935ED5")
        /// Destructive actions (e.g. delete)
        static let destructive = SwiftUI.Color(hex: "DD2340")
        /// Resurface indicator
        static let resurface = SwiftUI.Color(hex: "FFC57C")
        /// Fire indicator
        static let fire = SwiftUI.Color(hex: "F79CE1")
        /// Auth welcome sticky note
        static let stickyNoteYellow = SwiftUI.Color(hex: "EBCF47")
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
        /// Multi-line composer corner radius
        static let composerMultiLineRadius: CGFloat = 24
        /// Link card height
        static let linkCardHeight: CGFloat = 44
        /// Link card corner radius
        static let linkCardCornerRadius: CGFloat = 8

        // MARK: - Auth Layout (Auth-specific offsets)

        static let welcomeTopOffset: CGFloat = 140
        static let authHeaderTopOffset: CGFloat = 60
        static let separatorSpacingBelowHeader: CGFloat = 12
        static let kebabBelowHeader: CGFloat = 40
        static let bodyBelowKebab: CGFloat = 4
        static let inputBelowBody: CGFloat = 40
        static let primaryButtonBottomOffset: CGFloat = 40
        static let legalBelowSignIn: CGFloat = 24
        static let signInBelowPrimary: CGFloat = 12
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
        /// - 1–9 d    → "1d" … "9d"
        /// - ≥ 10 d   → existing absolute "MM/dd/yy • h:mma"
        static func relative(for date: Date, relativeTo now: Date = Date()) -> String {
            let age = max(0, now.timeIntervalSince(date))
            switch age {
            case ..<60:
                return "right now"
            case ..<3_600:
                return "\(Int(age / 60))m"
            case ..<86_400:
                return "\(Int(age / 3_600))h"
            case ..<(86_400 * 10):
                return "\(Int(age / 86_400))d"
            default:
                return absoluteFormatter.string(from: date)
            }
        }
    }
}

// MARK: - Color hex initializer

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

//
//  Style.swift
//  MicromsgiOS
//
//  Micromsg Visual System v1 — single source of truth for colors, typography, spacing, radii.
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
        static let composerSend = SwiftUI.Color(hex: "545FC6")
    }

    // MARK: - Typography (Phase 2: system fonts; flat hierarchy)

    enum Typography {
        /// Header title "kebab": monospaced, medium, 18pt, 24pt line height
        static func headerTitle() -> Font {
            .system(size: 18, weight: .medium)
                .monospaced()
        }
        /// Entry body: regular, 16pt, 24pt line height
        static func body() -> Font {
            .system(size: 16, weight: .regular)
        }
        /// Timestamp/overline, reply count: regular, 16pt, 24pt line height, use secondary color
        static func meta() -> Font {
            .system(size: 14, weight: .regular)
        }
        /// Composer placeholder: medium, 16pt, 24pt line height, use secondary color
        static func composerPlaceholder() -> Font {
            .system(size: 16, weight: .medium)
        }
        /// Composer active text: regular, 16pt, 24pt line height, use primary color
        static func composerText() -> Font {
            .system(size: 16, weight: .regular)
        }

        static let bodyLineHeight: CGFloat = 24
        static let metaLineHeight: CGFloat = 24
    }

    // MARK: - Spacing (base unit 4pt)

    enum Spacing {
        static let base: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        /// Timestamp row above body
        static let timestampAboveBody: CGFloat = 4
        /// Reply icon row below body
        static let replyBelowBody: CGFloat = 12
        /// Reply count below reply icon row
        static let replyCountBelowIcon: CGFloat = 8
        /// Composer inner padding vertical
        static let composerPaddingVertical: CGFloat = 12
        /// Composer inner padding left
        static let composerPaddingLeft: CGFloat = 16
        /// Composer text right margin from action button
        static let composerTextMarginRight: CGFloat = 12
        /// Composer action button inset from edges
        static let composerButtonInset: CGFloat = 6
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

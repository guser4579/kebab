import SwiftUI

/// First-run empty state for the All feed: in-moment onboarding shaped as a
/// question, not a tutorial. Behind the copy sits the data-sky at whisper
/// volume — a faint organized field of mono glyphs with a few tiny fragments
/// of an imagined kebab. The question reads first; the fragments are meant to
/// be discovered on a second look. There are no buttons here by design: the
/// composer below is the call to action.
struct AllFeedEmptyStateView: View {

    /// One mark in the glyph field. Coordinates are fractions of the
    /// available area so the arrangement holds across device sizes.
    private struct FieldGlyph {
        let symbol: String
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let opacity: Double
    }

    /// Hand-placed on a loose grid so the field reads as annotation, not
    /// noise. The band around y 0.36–0.56 stays clear (edges excepted) so
    /// the copy owns its space.
    private static let field: [FieldGlyph] = [
        .init(symbol: "+", x: 0.15, y: 0.07, size: 12, opacity: 0.40),
        .init(symbol: "·", x: 0.47, y: 0.07, size: 13, opacity: 0.35),
        .init(symbol: "×", x: 0.80, y: 0.06, size: 11, opacity: 0.30),
        .init(symbol: "·", x: 0.68, y: 0.13, size: 12, opacity: 0.35),
        .init(symbol: "·", x: 0.10, y: 0.19, size: 12, opacity: 0.35),
        .init(symbol: "+", x: 0.88, y: 0.19, size: 12, opacity: 0.40),
        .init(symbol: "×", x: 0.30, y: 0.24, size: 11, opacity: 0.28),
        .init(symbol: "·", x: 0.52, y: 0.23, size: 12, opacity: 0.32),
        .init(symbol: "+", x: 0.14, y: 0.31, size: 11, opacity: 0.35),
        .init(symbol: "·", x: 0.83, y: 0.32, size: 13, opacity: 0.38),
        .init(symbol: "·", x: 0.06, y: 0.40, size: 11, opacity: 0.25),
        .init(symbol: "·", x: 0.94, y: 0.39, size: 11, opacity: 0.25),
        .init(symbol: "×", x: 0.07, y: 0.49, size: 10, opacity: 0.22),
        .init(symbol: "+", x: 0.93, y: 0.50, size: 11, opacity: 0.25),
        .init(symbol: "·", x: 0.12, y: 0.57, size: 12, opacity: 0.32),
        .init(symbol: "·", x: 0.86, y: 0.57, size: 11, opacity: 0.30),
        .init(symbol: "+", x: 0.70, y: 0.64, size: 12, opacity: 0.35),
        .init(symbol: "×", x: 0.18, y: 0.70, size: 11, opacity: 0.30),
        .init(symbol: "·", x: 0.45, y: 0.70, size: 12, opacity: 0.32),
        .init(symbol: "·", x: 0.60, y: 0.79, size: 11, opacity: 0.28),
        .init(symbol: "+", x: 0.30, y: 0.79, size: 10, opacity: 0.26),
        .init(symbol: "·", x: 0.85, y: 0.78, size: 10, opacity: 0.24)
    ]

    private static let fragmentOpacity: Double = 0.65

    var body: some View {
        GeometryReader { geo in
            ZStack {
                bloom(in: geo.size)
                atmosphere(in: geo.size)
                copy(in: geo.size)
            }
        }
    }

    // MARK: - Copy

    /// Centered slightly above the geometric middle: calm, dominant, and far
    /// enough from the composer that the two never compete. The question
    /// stands alone — the fragments in the atmosphere are its only support.
    private func copy(in size: CGSize) -> some View {
        Text("What’s something you’d normally text yourself?")
            .font(Style.Typography.emptyStatePrompt())
            .foregroundColor(Style.Color.primaryText)
            .lineSpacing(8)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Style.Spacing.emptyStateMargin + Style.Spacing.x2)
            .frame(width: size.width)
            .position(x: size.width / 2, y: size.height * 0.44)
    }

    // MARK: - Bloom

    /// A faint smoky presence behind the composition — depth, not a shape.
    /// primaryText is ink in light and bone in dark, so one token gives the
    /// near-black bloom on the light surface and the soft off-white one on
    /// the dark surface. Centered slightly above the question; the falloff
    /// ends well short of the nav and composer, and the blur erases any
    /// readable edge.
    private func bloom(in size: CGSize) -> some View {
        RadialGradient(
            stops: [
                .init(color: Style.Color.primaryText.opacity(0.0535), location: 0),
                .init(color: Style.Color.primaryText.opacity(0.0214), location: 0.55),
                .init(color: .clear, location: 1)
            ],
            center: UnitPoint(x: 0.5, y: 0.41),
            startRadius: 0,
            endRadius: min(size.width * 0.75, size.height * 0.34)
        )
        .blur(radius: 32)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Atmosphere

    /// The glyph field and fragments, masked so the whole layer dissolves
    /// toward the composer area instead of ending at an edge.
    private func atmosphere(in size: CGSize) -> some View {
        ZStack {
            ForEach(Self.field.indices, id: \.self) { index in
                let glyph = Self.field[index]
                Text(glyph.symbol)
                    .font(Style.Typography.mono(size: glyph.size))
                    .foregroundColor(Style.Color.secondary)
                    .opacity(glyph.opacity)
                    .position(x: size.width * glyph.x, y: size.height * glyph.y)
            }

            fragment("remember her name — maya")
                .position(x: size.width * 0.36, y: size.height * 0.15)
            fragment("why do i think better on walks")
                .position(x: size.width * 0.60, y: size.height * 0.27)
            fragment("that ramen place on 5th")
                .position(x: size.width * 0.33, y: size.height * 0.63)
            linkFragment
                .position(x: size.width * 0.66, y: size.height * 0.72)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.58),
                    .init(color: .black.opacity(0.4), location: 0.80),
                    .init(color: .clear, location: 0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A whisper-volume trace of another kebab: plain mono text, no card, no
    /// chrome, nothing that reads as interactive.
    private func fragment(_ text: String) -> some View {
        Text(text)
            .font(Style.Typography.mono(size: 12))
            .foregroundColor(Style.Color.secondary)
            .opacity(Self.fragmentOpacity)
            .fixedSize()
    }

    private var linkFragment: some View {
        HStack(spacing: 4) {
            Icon("link-02", glyphSize: 11)
            Text("youtube.com")
                .font(Style.Typography.mono(size: 12))
        }
        .foregroundColor(Style.Color.secondary)
        .opacity(Self.fragmentOpacity)
        .fixedSize()
    }
}

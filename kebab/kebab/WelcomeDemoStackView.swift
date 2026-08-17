//
//  WelcomeDemoStackView.swift
//  kebab
//
//  Ambient product demonstration on the welcome screen: a deck of six
//  hand-built demo entries rendered in the app's real entry language
//  (typography, timestamps, thread lines, link cards, indicators), cycling
//  automatically. Pure presentation — no Entry models, no repositories, no
//  network, no feed/search participation.
//

import SwiftUI

// MARK: - Demo model

/// A static, display-only stand-in for an entry. Deliberately not `Entry`:
/// these never touch the database, the outbox, or search, so they carry only
/// what the welcome card renders.
struct WelcomeDemoEntry: Identifiable {

    enum LinkPreview {
        /// Thumbnail-on-top rich card (the RichLinkCardView full-card shape)
        /// with a locally drawn video-style thumbnail — no image loading.
        case video(title: String, domain: String, duration: String)
        /// Icon + title + domain row (the RichLinkCardView medium-card shape).
        case medium(title: String, domain: String)
    }

    struct Comment {
        let timestamp: String
        let text: String
    }

    let id: Int
    /// Pre-baked relative timestamp ("3h") — demo cards are frozen in time,
    /// so no TimelineView ticking like live rows.
    let timestamp: String
    let body: String
    var link: LinkPreview? = nil
    var comments: [Comment] = []
    var resurfaceCount: Int = 0
    var commentCount: Int = 0
    /// Text-only cards keep the root action row; link cards drop it so the
    /// tallest examples stay inside the fixed deck container.
    var showsActionRow: Bool = true
}

// MARK: - Deck

struct WelcomeDemoStackView: View {

    /// Fixed container height for the whole deck. Cards are bottom-aligned
    /// inside it: the container's bottom edge is the shared baseline every
    /// front card rests on, so short cards sit low (near the headline) and
    /// tall cards extend upward — and the welcome layout never moves.
    static let designHeight: CGFloat = 320

    /// How far below the baseline a hidden card waits before rising into
    /// the front position. Kept modest so a rising card never reads as
    /// crossing into the headline gap while it fades in.
    private static let riseDistance: CGFloat = 28

    private static let dwellNanos: UInt64 = 3_800_000_000
    private static let shuffleDuration: Double = 0.35

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var activeIndex = 0
    /// Brief upward breath of the peek strips while a shuffle is in flight.
    @State private var stripsNudged = false
    @State private var hasAppeared = false
    /// Natural height of each card, measured once at layout. The active
    /// card's height is what the peek strips hang off of, so they ride the
    /// front card's top edge instead of a fixed absolute position.
    @State private var cardHeights: [Int: CGFloat] = [:]

    private var activeCardHeight: CGFloat {
        cardHeights[activeIndex] ?? 200
    }

    private static let entries: [WelcomeDemoEntry] = [
        WelcomeDemoEntry(
            id: 0,
            timestamp: "3h",
            body: "Lupita\u{2019}s was the best Mexican I\u{2019}ve had in a while",
            comments: [.init(timestamp: "22m", text: "guava was easily the best marg in the flight")]
        ),
        WelcomeDemoEntry(
            id: 1,
            timestamp: "4h",
            body: "Nephew wants Pok\u{00E9}mon cards or Star Wars LEGOs \u{2014} bday in 6 months"
        ),
        WelcomeDemoEntry(
            id: 2,
            timestamp: "2d",
            body: "Tikka masala grilled cheese on naan",
            link: .video(
                title: "Tikka Masala Grilled Cheese on Naan",
                domain: "youtube.com",
                duration: "8:12"
            ),
            comments: [.init(timestamp: "6h", text: "have to make this for mom")],
            showsActionRow: false
        ),
        WelcomeDemoEntry(
            id: 3,
            timestamp: "1d",
            body: "boss sent me this \u{2014} should actually listen",
            link: .medium(
                title: "How great product teams stay fast | Lenny\u{2019}s Podcast",
                domain: "lennyspodcast.com"
            ),
            comments: [.init(timestamp: "4h", text: "loops + jigs are the thing worth stealing here")],
            showsActionRow: false
        ),
        WelcomeDemoEntry(
            id: 4,
            timestamp: "6d",
            body: "I wonder what the implications of a post-literate society might be...",
            resurfaceCount: 2,
            commentCount: 15
        ),
        WelcomeDemoEntry(
            id: 5,
            timestamp: "5d",
            body: "Jake said this physical therapist is the best in the city\n614-555-0187"
        )
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            // Persistent depth cues: two card silhouettes peeking above the
            // front card. The receding front card dissolves onto the nearer
            // strip, so the deck reads as constant while cards cycle through.
            if !reduceMotion {
                peekStrip(level: 2)
                peekStrip(level: 1)
            }

            ForEach(Self.entries) { entry in
                let role = ((activeIndex - entry.id) % Self.entries.count + Self.entries.count) % Self.entries.count
                WelcomeDemoCardView(entry: entry, colorScheme: colorScheme)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        cardHeights[entry.id] = $0
                    }
                    .scaleEffect(scale(for: role), anchor: .top)
                    .offset(y: offset(for: role))
                    .opacity(role == 0 ? 1 : 0)
                    .zIndex(Double(Self.entries.count - role))
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .frame(height: Self.designHeight, alignment: .bottom)
        .opacity(hasAppeared ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                hasAppeared = true
            }
        }
        // Restarts on scene changes and cancels on disappear, so nothing
        // fires while the welcome screen is hidden or the app is backgrounded.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.dwellNanos)
                guard !Task.isCancelled else { return }
                await shuffle()
            }
        }
    }

    /// One shuffle: the next card rises from below into front while the
    /// current front recedes and dissolves into the stack; the peek strips
    /// breathe upward and settle. Under Reduce Motion everything collapses
    /// to a plain crossfade at rest position.
    @MainActor
    private func shuffle() async {
        let animation: Animation = reduceMotion
            ? .easeInOut(duration: Self.shuffleDuration)
            : .spring(response: Self.shuffleDuration, dampingFraction: 0.9)
        withAnimation(animation) {
            activeIndex = (activeIndex + 1) % Self.entries.count
            stripsNudged = true
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.shuffleDuration * 1_000_000_000))
        withAnimation(.easeOut(duration: 0.2)) {
            stripsNudged = false
        }
    }

    // MARK: Deck geometry

    /// Offsets are relative to the container's bottom baseline: the front
    /// card rests on it (0), the receding card lifts slightly as it
    /// dissolves, and waiting cards sit just below it, ready to rise.
    private func offset(for role: Int) -> CGFloat {
        guard !reduceMotion else { return 0 }
        switch role {
        case 0: return 0
        case 1: return -8
        default: return Self.riseDistance
        }
    }

    private func scale(for role: Int) -> CGFloat {
        guard !reduceMotion else { return 1 }
        switch role {
        case 0: return 1
        case 1: return 0.95
        default: return 0.98
        }
    }

    /// Card-silhouette strip behind the deck; only its top edge shows above
    /// the front card. Level 1 is nearer (wider, lower), level 2 further.
    /// Positioned off the measured height of the active card, so the strips
    /// ride its top edge — and glide with it inside the shuffle animation
    /// whenever the incoming card is a different height.
    private func peekStrip(level: Int) -> some View {
        RoundedRectangle(cornerRadius: WelcomeDemoCardView.cornerRadius)
            .fill(Style.Color.composerBackground)
            .overlay(
                RoundedRectangle(cornerRadius: WelcomeDemoCardView.cornerRadius)
                    .strokeBorder(Style.Color.separator, lineWidth: 1)
            )
            .frame(height: 44)
            .padding(.horizontal, CGFloat(level) * 10)
            .offset(y: -(activeCardHeight + CGFloat(level) * 8 - 44) + (stripsNudged ? -2 : 0))
            .opacity(level == 2 ? 0.8 : 1)
    }
}

// MARK: - Demo card

/// One demo entry rendered in the app's real entry language: EntryRowView's
/// header/body/action-row structure and spacing, EntryDetailView's thread
/// treatment for comments, RichLinkCardView's card shapes for links — all on
/// the semantic surface tokens so light/dark just works.
struct WelcomeDemoCardView: View {

    static let cornerRadius: CGFloat = 16

    let entry: WelcomeDemoEntry
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rootSection
                .padding(.horizontal, Style.Layout.entryContentPadding)

            if !entry.comments.isEmpty {
                Color.clear
                    .frame(height: 8)

                commentThread
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Style.Color.separator, lineWidth: 1)
        )
        // Just enough lift to separate the card from the artwork beneath it;
        // in dark mode the hairline does the separating and the shadow only
        // grounds the card against the art.
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08),
            radius: 10,
            y: 4
        )
    }

    // MARK: Root entry (EntryRowView structure)

    private var rootSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Color.clear
                .frame(height: 4)

            Text(entry.body)
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let link = entry.link {
                Color.clear
                    .frame(height: 8)

                linkCard(link)
            }

            if entry.showsActionRow {
                Color.clear
                    .frame(height: 12)

                actionRow
            }

            if entry.commentCount > 0 {
                Color.clear
                    .frame(height: 8)

                Text(entry.commentCount == 1 ? "1 comment" : "\(entry.commentCount) comments")
                    .font(.custom("DMSans-Regular", size: 16))
                    .foregroundColor(Style.Color.secondary)
                    .frame(height: 24, alignment: .leading)
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text(entry.timestamp)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)

            if entry.resurfaceCount > 0 {
                HStack(spacing: 0) {
                    Icon("refresh-04", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.resurface)

                    Text("\(entry.resurfaceCount)")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.resurface)
                }
                .padding(.leading, 2)
            }

            Spacer(minLength: 0)

            Icon("ellipsis", glyphSize: Style.Icon.glyphSmall)
                .foregroundColor(Style.Color.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: Style.Spacing.x4) {
            Icon("message-circle")
                .foregroundColor(Style.Color.secondary)

            Icon("refresh-04")
                .foregroundColor(Style.Color.secondary)

            Icon("fire-03")
                .foregroundColor(Style.Color.secondary)
        }
        .frame(minHeight: 24, alignment: .leading)
    }

    // MARK: Comment thread (EntryDetailView treatment)

    private var commentThread: some View {
        VStack(spacing: 0) {
            ForEach(Array(entry.comments.enumerated()), id: \.offset) { index, comment in
                VStack(spacing: 0) {
                    if index > 0 {
                        Rectangle()
                            .fill(Style.Color.separator)
                            .frame(height: 1)
                            .padding(.leading, 17)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 10)

                        HStack {
                            Text(comment.timestamp)
                                .font(Style.Typography.meta())
                                .foregroundColor(Style.Color.secondary)

                            Spacer(minLength: 0)

                            Icon("ellipsis", glyphSize: Style.Icon.glyphSmall)
                                .foregroundColor(Style.Color.secondary)
                        }

                        Color.clear
                            .frame(height: 4)

                        Text(comment.text)
                            .font(Style.Typography.body())
                            .foregroundColor(Style.Color.primaryText)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Color.clear
                            .frame(height: 2)
                    }
                    .padding(.leading, 33)
                    .padding(.trailing, Style.Layout.entryContentPadding)
                }
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Style.Color.separator)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.leading, 16)
        }
    }

    // MARK: Link previews (RichLinkCardView shapes, static demo metadata)

    @ViewBuilder
    private func linkCard(_ link: WelcomeDemoEntry.LinkPreview) -> some View {
        switch link {
        case .video(let title, let domain, let duration):
            videoLinkCard(title: title, domain: domain, duration: duration)
        case .medium(let title, let domain):
            mediumLinkCard(title: title, domain: domain)
        }
    }

    private func videoLinkCard(title: String, domain: String, duration: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            videoThumbnail(duration: duration)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Style.Typography.linkCard())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(domain)
                    .font(.custom("DMSans-Regular", size: 12))
                    .foregroundColor(Style.Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .background(Style.Color.background)
        .clipShape(RoundedRectangle(cornerRadius: Style.Layout.linkCardThumbnailCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Style.Layout.linkCardThumbnailCornerRadius)
                .strokeBorder(Style.Color.separator, lineWidth: 1)
        )
    }

    /// Locally drawn video-style thumbnail — a warm abstract wash with a play
    /// badge and duration chip. Vector all the way down: sharp at any size,
    /// zero image loading.
    private func videoThumbnail(duration: String) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        SwiftUI.Color(hex: "D98E4A"),
                        SwiftUI.Color(hex: "A93F2B")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .fill(SwiftUI.Color(hex: "F03"))
                    .frame(width: 38, height: 26)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(duration)
                    .font(.custom("DMSans-Medium", size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.black.opacity(0.7))
                    )
                    .padding(6)
            }
            .clipped()
    }

    private func mediumLinkCard(title: String, domain: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Icon("link-02")
                .foregroundColor(Style.Color.primaryText)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Style.Typography.linkCard())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(2)

                Text(domain)
                    .font(.custom("DMSans-Regular", size: 12))
                    .foregroundColor(Style.Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Style.Layout.linkCardCornerRadius)
                .fill(Style.Color.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Style.Layout.linkCardCornerRadius)
                .strokeBorder(Style.Color.separator, lineWidth: 1)
        )
    }
}

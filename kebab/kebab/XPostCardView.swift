//
//  XPostCardView.swift
//  kebab
//

import SwiftUI

/// A saved X post, rendered natively.
///
/// This is a Kebab entry's *source*, not X inside Kebab: it wears the same
/// container as `RichLinkCardView` (app background, hairline, thumbnail
/// corner radius) and the same type ramp as the rest of the feed. There is no
/// engagement chrome, no reply affordance, and nothing about it is a web view
/// — every pixel is SwiftUI over persisted metadata.
///
/// Everything is static at render time. No network work starts here; images go
/// through the shared `CachedAsyncImage` path the rest of the feed uses, and
/// every media box reserves its height from the persisted dimensions so the
/// row never snaps when an image arrives.
///
/// One tap target: the footer opens the canonical post on X through the app's
/// existing in-app browser. The rest of the card is hit-transparent so a feed
/// row's `NavigationLink` still opens the entry, exactly like the split-target
/// behavior in `RichLinkCardView`.
struct XPostCardView: View {

    let post: XPostSource

    @State private var isShowingSafari = false

    private var canonicalURL: URL? {
        URL(string: post.url)
    }

    // Media boxes are sized from X's reported dimensions. Clamped so a very
    // tall portrait image can't take over the feed, and given a sane default
    // when dimensions are missing.
    private static let defaultAspectRatio: CGFloat = 1.5
    private static let aspectRange: ClosedRange<CGFloat> = 0.8...2.0

    private static let mediaCornerRadius: CGFloat = 12
    // Matches EntryImageStripView, so a post's photos and an entry's own
    // photos read as the same kind of object.
    private static let stripCellWidth: CGFloat = 221
    private static let stripCellHeight: CGFloat = 175

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            authorRow
            postText
            media
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hit-transparent surfaces: a plain filled background would swallow
        // taps before they reached the feed row's NavigationLink underneath.
        .background(
            RoundedRectangle(cornerRadius: Style.Layout.linkCardThumbnailCornerRadius)
                .fill(Style.Color.background)
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: Style.Layout.linkCardThumbnailCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Style.Layout.linkCardThumbnailCornerRadius)
                .strokeBorder(Style.Color.separator, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .fullScreenCover(isPresented: $isShowingSafari) {
            if let canonicalURL {
                SafariView(url: canonicalURL)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Author

    private var authorRow: some View {
        HStack(spacing: 8) {
            avatar

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(post.author.name)
                        .font(.custom("DMSans-Medium", size: 14))
                        .foregroundColor(Style.Color.primaryText)
                        .lineLimit(1)

                    if post.author.isVerified {
                        // Restrained on purpose: Kebab's secondary tint, not
                        // X's badge color.
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Style.Color.secondary)
                    }
                }

                Text("@\(post.author.username)")
                    .font(.custom("DMSans-Regular", size: 12))
                    .foregroundColor(Style.Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(authorAccessibilityLabel)
    }

    private var authorAccessibilityLabel: String {
        var label = "Post by \(post.author.name), at \(post.author.username)"
        if post.author.isVerified { label += ", verified" }
        return label
    }

    private var avatar: some View {
        Circle()
            .fill(Style.Color.separator)
            .frame(width: 36, height: 36)
            .overlay {
                CachedAsyncImage(url: post.author.profile_image_url.flatMap(URL.init(string:)))
            }
            .clipShape(Circle())
    }

    // MARK: - Post text

    @ViewBuilder
    private var postText: some View {
        if !post.text.isEmpty {
            // Imported source content. Never merged into the entry's own text,
            // and never presented as something the user wrote.
            Text(post.text)
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityLabel(post.text)
        }
    }

    // MARK: - Media

    @ViewBuilder
    private var media: some View {
        let photos = post.photos

        if photos.count == 1, let photo = photos.first, let url = photo.url.flatMap(URL.init(string:)) {
            mediaBox(url: url, ratio: aspectRatio(for: photo), label: photo.alt_text ?? "Image in the post")
                .allowsHitTesting(false)

        } else if photos.count > 1 {
            // Same strip language as an entry's own photos.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(photos, id: \.key) { photo in
                        Rectangle()
                            .fill(Style.Color.separator)
                            .frame(width: Self.stripCellWidth, height: Self.stripCellHeight)
                            .overlay {
                                CachedAsyncImage(url: photo.url.flatMap(URL.init(string:)))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Self.mediaCornerRadius))
                            .accessibilityLabel(photo.alt_text ?? "Image in the post")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
            .frame(height: Self.stripCellHeight)

        } else if let unsupported = post.unsupported_media {
            unsupportedMedia(kind: unsupported)
                .allowsHitTesting(false)
        }
    }

    /// Video and GIF posts keep everything that is reliable — author, text,
    /// timestamp — plus X's own still frame, labelled so it is obvious the
    /// motion lives on X. Kebab has no X video player and is not getting one.
    @ViewBuilder
    private func unsupportedMedia(kind: String) -> some View {
        let frame = post.media.first { $0.type != "photo" }
        let label = kind == "animated_gif" ? "GIF on X" : "Video on X"

        if let previewURL = frame?.preview_image_url.flatMap(URL.init(string:)) {
            mediaBox(url: previewURL, ratio: aspectRatio(for: frame), label: label)
                .overlay(alignment: .bottomLeading) {
                    mediaBadge(label)
                        .padding(8)
                }
                .accessibilityLabel(label)
        } else {
            HStack {
                mediaBadge(label)
                Spacer(minLength: 0)
            }
        }
    }

    private func mediaBadge(_ label: String) -> some View {
        Text(label)
            .font(Style.Typography.meta())
            .foregroundColor(Style.Color.composerSendForeground)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Style.Color.composerSend.opacity(0.85)))
    }

    /// A fixed-ratio container that exists before its image does — the box is
    /// the layout, the image just fills it. Nothing about loading changes the
    /// row's height.
    private func mediaBox(url: URL, ratio: CGFloat, label: String) -> some View {
        Rectangle()
            .fill(Style.Color.separator)
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                CachedAsyncImage(url: url)
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.mediaCornerRadius))
            .accessibilityLabel(label)
    }

    private func aspectRatio(for media: XPostMedia?) -> CGFloat {
        guard let ratio = media?.aspectRatio else { return Self.defaultAspectRatio }
        return min(max(ratio, Self.aspectRange.lowerBound), Self.aspectRange.upperBound)
    }

    // MARK: - Source affordance

    private var footer: some View {
        Button {
            isShowingSafari = true
        } label: {
            HStack(spacing: 4) {
                Text(footerText)
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
                    .lineLimit(1)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Style.Color.secondary)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(canonicalURL == nil)
        .accessibilityLabel("Open this post on X")
        .accessibilityHint(footerText)
    }

    private var footerText: String {
        guard let date = post.createdAtDate else { return "X" }
        return "\(Style.Timestamp.sourceDate(for: date)) · X"
    }
}

import SwiftUI

/// Rich link preview card for root entries.
///
/// Renders one of three states based on what metadata is available in the attachment:
///
///   - Full rich card  (title + image_url): 200pt image on top, title below, domain below that.
///   - Medium card     (title, no image):   link icon + title + domain, variable height.
///   - Compact fallback (no title):         delegates entirely to the existing LinkCardView.
///
/// All inputs are static at render time — no async fetching happens inside this view.
/// The image is loaded by AsyncImage from the stored og:image URL; its container is a
/// fixed 200pt height so layout is stable regardless of network speed or image dimensions.
///
/// Tapping any card variant opens the existing SafariView in-app browser path.
struct RichLinkCardView: View {

    let urlString: String
    let title: String?
    let imageURL: String?

    @State private var isShowingSafari = false

    // Trimmed, non-empty title — nil if the stored title is absent or whitespace-only.
    private var effectiveTitle: String? {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // Parsed image URL — nil if imageURL is absent, empty, or not a valid URL.
    private var parsedImageURL: URL? {
        guard let raw = imageURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var displayDomain: String {
        LinkCardView.displayURL(from: urlString)
    }

    var body: some View {
        if let effectiveTitle {
            if let url = URL(string: urlString) {
                richButton(url: url, title: effectiveTitle)
            } else {
                // Valid title, unparseable URL (defensive — attachments always come from NSDataDetector).
                mediumCard(title: effectiveTitle)
            }
        } else {
            // No title: delegate entirely to the existing compact fallback.
            // LinkCardView owns its own tap handling and SafariView presentation.
            LinkCardView(urlString: urlString, title: title)
        }
    }

    // MARK: - Card button wrapper

    private func richButton(url: URL, title: String) -> some View {
        Button {
            isShowingSafari = true
        } label: {
            if let imgURL = parsedImageURL {
                fullRichCard(title: title, imageURL: imgURL)
            } else {
                mediumCard(title: title)
            }
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $isShowingSafari) {
            SafariView(url: url)
                .ignoresSafeArea()
        }
    }

    // MARK: - Full rich card (image + title + domain)

    private func fullRichCard(title: String, imageURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image container is always exactly 200pt tall.
            // The separator-colored Rectangle is the stable placeholder — it never changes size.
            // AsyncImage renders on top of it via overlay; scaledToFill fills the fixed bounds.
            // If the image fails to load, the separator background remains, which is acceptable.
            Rectangle()
                .fill(Style.Color.separator)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .overlay {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            Color.clear
                        }
                    }
                }
                .clipped()

            // Text region
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Style.Typography.linkCard())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(displayDomain)
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
        .clipShape(RoundedRectangle(cornerRadius: Style.Layout.linkCardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Style.Layout.linkCardCornerRadius)
                .strokeBorder(Style.Color.separator, lineWidth: 1)
        )
    }

    // MARK: - Medium card (title + domain, no image)

    private func mediumCard(title: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Icon("link-02")
                .foregroundColor(Color(hex: "4597F7"))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Style.Typography.linkCard())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(2)

                Text(displayDomain)
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

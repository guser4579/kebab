import SwiftUI

/// Renders comment body text with any detected URLs presented as lightweight
/// link cards below the text body — identical in appearance to the `LinkCardView`
/// compact fallback used for root-entry URL attachments.
///
/// Raw URL strings are removed from the visible body text so they are not
/// displayed twice. Adjacent whitespace left by the removal is collapsed, and
/// lines that become empty after URL removal are dropped.
///
/// Plain text remains non-interactive (`.allowsHitTesting(false)`), so taps on
/// the text body pass through to the row's background `NavigationLink`. Each
/// link card is an independent `LinkCardView` that owns its own in-app browser
/// presentation.
struct CommentLinkText: View {

    let text: String

    // One shared detector — NSDataDetector is expensive to construct.
    private static let detector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // MARK: - Parsed result

    private struct Parsed {
        /// Body text with all URL substrings removed and whitespace normalized.
        let strippedText: String
        /// Unique URLs in order of first appearance, used to build link cards.
        let urls: [URL]
    }

    /// Runs detection once and returns both the stripped body text and the
    /// deduplicated URL list so `body` only pays the cost once per evaluation.
    private var parsed: Parsed {
        guard !text.isEmpty, let detector = Self.detector else {
            return Parsed(strippedText: text, urls: [])
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: nsRange)

        guard !matches.isEmpty else {
            return Parsed(strippedText: text, urls: [])
        }

        // Collect every range for stripping (including duplicate URLs) and
        // unique URLs for card rendering.
        var allRanges: [NSRange] = []
        var seen = Set<String>()
        var urls: [URL] = []
        for match in matches {
            guard let url = match.url else { continue }
            allRanges.append(match.range)
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }

        return Parsed(strippedText: stripped(from: text, removing: allRanges), urls: urls)
    }

    // MARK: - Text stripping

    /// Returns `string` with the substrings at `ranges` removed and the
    /// resulting whitespace normalized.
    private func stripped(from string: String, removing ranges: [NSRange]) -> String {
        // Remove in reverse order so earlier indices remain valid.
        var result = string
        for nsRange in ranges.sorted(by: { $0.location > $1.location }) {
            guard let range = Range(nsRange, in: result) else { continue }
            result.replaceSubrange(range, with: "")
        }

        // Normalize per-line: collapse runs of horizontal whitespace to a
        // single space, trim each line, then drop lines that are now empty.
        let cleaned = result
            .components(separatedBy: "\n")
            .map { line in
                line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    // MARK: - Body

    var body: some View {
        let p = parsed
        VStack(alignment: .leading, spacing: 0) {
            if !p.strippedText.isEmpty {
                Text(p.strippedText)
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Non-interactive: taps pass through to the row's NavigationLink.
                    .allowsHitTesting(false)
            }

            if !p.urls.isEmpty {
                // Only add the gap when there is body text above the cards.
                if !p.strippedText.isEmpty {
                    Color.clear.frame(height: 8)
                }

                ForEach(Array(p.urls.enumerated()), id: \.element.absoluteString) { index, url in
                    if index > 0 {
                        Color.clear.frame(height: 4)
                    }
                    LinkCardView(urlString: url.absoluteString)
                }
            }
        }
    }
}

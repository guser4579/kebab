import SwiftUI

struct LinkCardView: View {

    let urlString: String

    var body: some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                cardContent
            }
            .buttonStyle(.plain)
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Style.Color.secondary)
                .frame(width: Style.Icon.grid, height: Style.Icon.grid)

            Text(Self.displayURL(from: urlString))
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Style.Layout.linkCardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: Style.Layout.linkCardCornerRadius))
    }

    static func displayURL(from urlString: String) -> String {
        guard let components = URLComponents(string: urlString) else {
            return urlString
        }

        var host = components.host ?? urlString
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }

        var path = components.path
        if path == "/" || path.isEmpty {
            return host
        }
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }

        return host + path
    }
}

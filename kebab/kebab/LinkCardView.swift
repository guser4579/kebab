import SwiftUI

struct LinkCardView: View {

    let urlString: String
    var title: String? = nil

    @State private var isShowingSafari = false

    private var displayText: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return Self.displayURL(from: urlString)
    }

    var body: some View {
        if let url = URL(string: urlString) {
            Button {
                isShowingSafari = true
            } label: {
                cardContent
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $isShowingSafari) {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        HStack(spacing: 12) {
            Icon("link-02")
                .foregroundColor(Color(hex: "4597F7"))

            Text(displayText)
                .font(Style.Typography.linkCard())
                .foregroundColor(Style.Color.primaryText)
                .underline()
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Style.Layout.linkCardHeight)
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

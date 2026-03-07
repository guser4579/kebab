import SwiftUI

struct EntryRowView: View {

    let entry: Entry
    var onMoreTapped: (() -> Void)?

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy • h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private var formattedTimestamp: String {
        Self.timestampFormatter.string(from: entry.created_at)
    }

    var body: some View {
        VStack(spacing: 0) {
            topSeparator

            Color.clear
                .frame(height: 16)

            entryContent

            Color.clear
                .frame(height: 16)

            bottomSeparator
        }
    }

    private var entryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Color.clear
                .frame(height: 4)

            contentText

            Color.clear
                .frame(height: 12)

            actionRow
        }
        .padding(.horizontal, Style.Layout.entryContentPadding)
    }

    private var topSeparator: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var bottomSeparator: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var headerRow: some View {
        HStack {
            Text(formattedTimestamp)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)

            Spacer(minLength: 0)

            Button {
                onMoreTapped?()
            } label: {
                Icon("ellipsis", glyphSize: Style.Icon.glyphSmall)
                    .foregroundColor(Style.Color.secondary)
            }
        }
    }

    private var contentText: some View {
        Text(entry.content)
            .font(Style.Typography.body())
            .foregroundColor(Style.Color.primaryText)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: Style.Spacing.replyBelowBody) {
            Button {
                print("comment tapped")
            } label: {
                Icon("message-circle")
                    .foregroundColor(Style.Color.secondary)
            }

            Button {
                print("pin tapped")
            } label: {
                Icon("pin")
                    .foregroundColor(Style.Color.secondary)
            }
        }
        .frame(minHeight: 24, alignment: .leading)
    }
}

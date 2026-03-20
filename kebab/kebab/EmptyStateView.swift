import SwiftUI

struct EmptyStateView: View {

    let iconName: String
    let title: String
    let primaryBody: String
    let secondaryBody: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Style.Spacing.x3) {
                Icon(iconName)
                Text(title)
                    .font(Style.Typography.emptyStateTitle())
                    .lineSpacing(Style.Typography.bodyLineHeight - 16)
            }
            .foregroundColor(Style.Color.primaryText)

            Color.clear
                .frame(height: Style.Spacing.x4)

            Text(primaryBody)
                .modifier(Style.Typography.bodyText())
                .foregroundColor(Style.Color.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(height: Style.Spacing.x2 + 4)

            Text(secondaryBody)
                .font(Style.Typography.meta())
                .lineSpacing(6)
                .foregroundColor(Style.Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

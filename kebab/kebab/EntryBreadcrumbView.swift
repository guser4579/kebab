import SwiftUI

/// Inline collection breadcrumb used in feed row headers, search result row headers,
/// and the entry detail header.
///
/// Renders nothing when `collectionName` is nil. When a parent name is present it
/// formats as "Parent / Child"; otherwise just "Name".
///
/// Color is `Style.Color.secondary` (#575B61) for both the icon and the text,
/// matching the timestamp and counter meta color.
struct EntryBreadcrumbView: View {

    let collectionName: String?
    let collectionParentName: String?

    private var label: String? {
        guard let name = collectionName else { return nil }
        if let parent = collectionParentName {
            return "\(parent) / \(name)"
        }
        return name
    }

    var body: some View {
        if let label {
            HStack(spacing: 3) {
                Icon("folder", glyphSize: Style.Icon.glyphSmall)
                    .foregroundColor(Style.Color.secondary)
                Text(label)
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

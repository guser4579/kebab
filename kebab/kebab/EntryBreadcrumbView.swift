import SwiftUI

/// Inline collection breadcrumb used in feed row headers, search result row headers,
/// and the entry detail header.
///
/// Renders nothing when `collectionName` is nil. When a parent name is present it
/// formats as "Parent / Child"; otherwise just "Name".
///
/// Color is `Style.Color.secondary` (#575B61), matching the timestamp and
/// counter meta color.
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
            Text(label)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

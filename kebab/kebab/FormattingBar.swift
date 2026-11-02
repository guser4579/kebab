//
//  FormattingBar.swift
//  kebab
//
//  The floating glass capsule above the keyboard in the full-screen editor.
//  It rides the keyboard as the text view's inputAccessoryView. All it does is
//  report taps: every operation is a pure function in MarkupEditing.
//

import Combine
import SwiftUI
import UIKit

enum FormattingAction {
    case list(MarkupEditing.ListAction)
    case inline(MarkupEditing.InlineAction)
    case indent
    case outdent
}

@MainActor
final class FormattingBarModel: ObservableObject {
    @Published var active = MarkupEditing.ActiveFormats()
    var perform: (FormattingAction) -> Void = { _ in }
}

struct FormattingBar: View {

    @ObservedObject var model: FormattingBarModel

    static let capsuleHeight: CGFloat = 52
    static let keyboardGap: CGFloat = 8

    private let buttonSize: CGFloat = 44

    var body: some View {
        ViewThatFits(in: .horizontal) {
            buttons(flexible: true)
            ScrollView(.horizontal, showsIndicators: false) {
                buttons(flexible: false)
            }
        }
        .frame(height: Self.capsuleHeight)
        .clipShape(Capsule())
        .kebabGlass(in: Capsule())
        // The composer capsule's inset.
        .padding(.horizontal, Style.Spacing.x4)
        .padding(.bottom, Self.keyboardGap)
    }

    private func buttons(flexible: Bool) -> some View {
        HStack(spacing: 0) {
            button("check-list", "Checklist", isActive: model.active.checklist, flexible) { .list(.checklist) }
            button("left-to-right-list-bullet", "Bullets", isActive: model.active.bullet, flexible) { .list(.bullet) }
            button("left-to-right-list-number", "Numbers", isActive: model.active.numbered, flexible) { .list(.numbered) }
            divider
            button("text-indent-less", "Outdent", isEnabled: model.active.canIndent, flexible) { .outdent }
            button("text-indent-more", "Indent", isEnabled: model.active.canIndent, flexible) { .indent }
            divider
            button("text-bold", "Bold", isActive: model.active.bold, flexible) { .inline(.bold) }
            button("text-italic", "Italic", isActive: model.active.italic, flexible) { .inline(.italic) }
            button("text-strikethrough", "Strikethrough", isActive: model.active.strikethrough, flexible) { .inline(.strikethrough) }
        }
        .padding(.horizontal, Style.Spacing.x4)
    }

    private var divider: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(width: 1, height: 20)
    }

    private func button(
        _ icon: String,
        _ label: String,
        isActive: Bool = false,
        isEnabled: Bool = true,
        _ flexible: Bool,
        action: @escaping () -> FormattingAction
    ) -> some View {
        Button {
            model.perform(action())
        } label: {
            Icon(icon)
                .foregroundColor(Style.Color.primaryText)
                .frame(width: 36, height: 36)
                .background {
                    if isActive {
                        Capsule().fill(Style.Color.primaryText.opacity(0.12))
                    }
                }
                .frame(minWidth: buttonSize, maxWidth: flexible ? .infinity : buttonSize)
                .frame(height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Fully transparent: only the capsule inside it is visible.
final class FormattingAccessoryView: UIView {

    init(hosting: UIView) {
        let height = FormattingBar.capsuleHeight + FormattingBar.keyboardGap
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear
        hosting.frame = bounds
        hosting.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: FormattingBar.capsuleHeight + FormattingBar.keyboardGap)
    }
}

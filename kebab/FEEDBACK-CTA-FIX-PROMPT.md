# Claude Code prompt — kebab feedback CTA, icon fix

Copy everything below the line into Claude Code from the kebab repo root.

---

The custom antenna mark I had you build for the feedback CTA doesn't work — at 20pt it reads as a smudge, and the green core looks like dirt. Rip it out and use a standard app icon instead. Everything else about the capsule stays as it is.

## 1. Delete the custom mark

In `SettingsView.swift`, delete the `FeedbackBeacon` view and its backing `Shape` entirely. Delete any `@State` that existed only to drive it.

## 2. Delete the colour token

In `Style.swift`, delete the `beacon` token. Confirm with a grep that nothing references `Style.Color.beacon` anywhere in the target.

## 3. Use a standard icon

In `feedbackCTA`, replace the custom mark with the app's existing icon component:

```
Icon("message-circle")
    .foregroundColor(Style.Color.primaryText)
```

`message-circle` already ships in `Icons/` and is rendered as a template elsewhere in the app, so it inherits the standard `Style.Icon.glyph` (21pt) inside the `Style.Icon.grid` (24pt) frame with no size overrides. Do not pass a custom `glyphSize`. Do not add a new SVG.

**No colour.** The icon is `primaryText`, the same tint as the label beside it — one weight, one colour, one object. No opacity reduction, no secondary tint, no accent of any kind anywhere in this capsule.

## 4. Everything else is unchanged

Do not touch:

- The label: `send feedback`, lowercase, `DMSans-Medium` 16, `primaryText`.
- The `HStack(spacing: Style.Spacing.x2)`, centred, `maxWidth: .infinity`, `height: 52`.
- The `composerBackground` fill and `containerCornerRadius` clip.
- `.buttonStyle(.plain)`, no press state, no haptic.
- The action: `withAnimation(Self.pushTransition) { openDetail = .feedback }`.
- The bottom padding in `rootPage`.
- `FeedbackPageView` and everything downstream of it.

Nothing animates.

## 5. Acceptance

1. Builds. The capsule shows a plain message-circle glyph and `send feedback`, both in `primaryText`, optically centred as one unit.
2. The icon is the same size and weight as the icons in the Appearance / Manage account rows above it.
3. Zero colour in the Menu panel.
4. `grep -rn "beacon" ` returns nothing in the app target.
5. No leftover unused shapes, states, or helper views in `SettingsView.swift`.

Show me the diff when you're done.

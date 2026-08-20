# Claude Code prompt — kebab feedback CTA (menu panel)

Copy everything below the line into Claude Code from the kebab repo root.

---

I'm replacing the feedback CTA at the foot of the Menu panel. This is a **presentation-only change** — the destination, the tap behaviour, and every other row in the panel stay exactly as they are. Two files change: `Style.swift` (one new colour token) and `SettingsView.swift` (one replaced view + one padding value).

## 0. What exists today

`SettingsView.swift` has a private computed view `feedbackCard` — a 168pt full-bleed `Image("FeedbackArt")` with a bottom scrim and two lines of white copy. It is placed in `rootPage` after `Spacer(minLength: 0)` with `.padding(.horizontal, 16).padding(.bottom, 48)`, and its action is `withAnimation(Self.pushTransition) { openDetail = .feedback }`.

Replace the card. **Keep the action byte-for-byte.**

## 1. New colour token

In `Style.Color`, add one token next to the existing `successBackground` / `successForeground` pair:

| New token | Light | Dark | Used for |
|---|---|---|---|
| `beacon` | `#3D7A47` | `#9DCB9F` | the lit core of the feedback CTA's antenna mark — nothing else |

Use the existing `dynamic(light:dark:)` helper. These are deliberately the same values as `successForeground`; they get their own name because the role is different and the two should be free to diverge. Do not reuse `successForeground` here.

This is the only saturated pixel allowed in the Menu panel. It must not appear anywhere else.

## 2. The antenna mark

Add a small private `Shape` + wrapper view to `SettingsView.swift` (bottom of the file, above the preview if there is one). It is drawn, not an asset — the arcs, the stem, and the core need independent tinting, which a single-colour SVG template can't do.

Geometry is authored in a **24×24 space** and scaled to whatever frame it's given (`let s = rect.width / 24`):

- **Core** — filled circle, centre `(12, 13)`, diameter `5`.
- **Stem** — line from `(12, 16.5)` to `(12, 21)`, stroke `1.6`, round cap.
- **Inner arc** — `addArc(center: (12, 13), radius: 5.4, startAngle: .degrees(225), endAngle: .degrees(315), clockwise: false)`, stroke `1.6`, round cap.
- **Outer arc** — same centre and angles, radius `9.4`, stroke `1.6`, round cap.

Both arcs open upward. The result is an aerial: a lit core with a stem below and two signal arcs rising above it.

Structure it as a `ZStack` of two layers so the tints are independent:

- **Arcs + stem** (one `Shape`, one `Path` with all three sub-paths, stroked): `Style.Color.primaryText.opacity(0.55)`.
- **Core** (a separate `Circle`, or a second `Shape`, filled): `Style.Color.beacon`.

Render it at a **20pt** glyph inside a `Style.Icon.grid` (24pt) frame, matching how `Icon` sizes everything else.

Do **not** animate it. See §5 for the one exception, which is opt-in.

## 3. The capsule

Replace `feedbackCard` with `feedbackCTA`:

```
Button {
    withAnimation(Self.pushTransition) { openDetail = .feedback }   // unchanged
} label: {
    HStack(spacing: Style.Spacing.x2) {                             // 8
        FeedbackBeacon()
        Text("send feedback")
            .font(.custom("DMSans-Medium", size: 16))
            .foregroundColor(Style.Color.primaryText)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 52)
    .background(Style.Color.composerBackground)
    .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))   // 16
    .contentShape(RoundedRectangle(cornerRadius: containerCornerRadius))
}
.buttonStyle(.plain)
```

Notes on the details, so you don't "improve" them:

- The label is **lowercase**. `send feedback`, not `Send feedback`. That is a voice decision, not an oversight.
- The content is **centred**, not leading-aligned. The mark and the label sit together in the middle as one unit.
- Fill is `composerBackground` — the same surface as the menu groups above it, so the capsule reads as part of the panel's material rather than a promotional object.
- No border, no shadow, no gradient, no tint on the capsule itself.
- No press-state scale or opacity animation. Every other button in this panel is `.plain` with no press feedback; match them.
- No haptic.

## 4. Position

In `rootPage`, change the CTA's bottom padding:

```
feedbackCTA
    .padding(.horizontal, 16)
    .padding(.bottom, 32)      // was 48
```

The panel uses `.ignoresSafeArea(edges: .all)`, so this is measured from the physical bottom of the screen. 32 puts the capsule's lower edge about 11pt above the top of the home indicator — visibly lower than today without crowding it. If it reads tight on device, 36 is the fallback; do not go below 28.

Leave `.padding(.horizontal, 16)` alone — the capsule spans the same gutter as the menu groups.

## 5. Optional — one-shot signal on panel open

**Skip this section unless I've said I want it.** If I have:

When the Menu panel finishes opening, animate the two arcs once: inner arc fades `0 → 1` over 0.22s, outer arc fades `0 → 1` over 0.22s beginning 0.12s later, both `.easeOut`. The core and stem are always fully visible and never animate. After the sequence the mark is static forever.

It must fire on the panel's open transition only, never on a timer, never on appear-while-already-open, and never repeat. Drive it from a single `@State private var beaconRevealed = false` that is set once and reset only when the panel closes.

**There is no looping, pulsing, or blinking state.** A blink in persistent navigation is notification grammar — it claims something is waiting for you, which is false here, and it becomes a badge that can never be cleared.

## 6. Copy alignment on the destination page (do this)

`FeedbackPageView.swift` line ~137 has the heading `Text("Offer your feedback")`. Change it to `Text("Send feedback")` so the menu label and the page title agree. The page's own submit button already says "Send feedback"; leave it.

Leave the body copy on line ~61 alone.

## 7. Explicitly out of scope

- No changes to any other row, group, or page in `SettingsView`.
- No changes to `FeedbackRepository`, the submit flow, or anything the page does.
- Do not delete `Assets.xcassets/FeedbackArt.imageset` — it becomes unreferenced, and that's fine. Leave it in the repo.
- No new dependencies, no new files unless you decide the beacon shape is cleaner in its own file (it isn't — keep it private in `SettingsView.swift`).
- No changes to spacing, radius, or typography constants at the top of `SettingsView`.

## 8. Acceptance checklist

1. Builds and runs. Tapping the capsule pushes the same feedback page as before, with the same animation.
2. Dark: soot capsule (`#1A1A1B`) on the near-black panel, bone label, arcs at 55% bone, a small pale-green core. The green is the only colour in the panel and reads as a quiet indicator, not a badge.
3. Light: white capsule on greige, ink label, arcs at 55% ink, a deep-green core.
4. The capsule sits noticeably lower than the old card did and clears the home indicator on a device with a safe-area inset.
5. Nothing on screen pulses, blinks, or loops.
6. `Style.Color.beacon` appears in exactly one place in the codebase outside `Style.swift`.

When you're done, show me the diff for `SettingsView.swift` and tell me the final bottom-padding value you settled on.

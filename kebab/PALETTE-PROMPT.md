# Claude Code prompt — kebab palette swap + appearance toggle

Copy everything below the line into Claude Code from the kebab repo root.

---

I'm updating kebab's color palette. This is a **colors-only change** — do not alter any layout, spacing, component structure, navigation, or behavior, with one exception: add an appearance toggle row to `SettingsView` (spec below). Do not rename any existing `Style.Color` API — every view keeps compiling against the same names.

## 1. Architecture: dynamic colors, zero view churn

`Style.swift` currently defines static `SwiftUI.Color` values from hex. Replace each with a **dynamic color** that resolves per color scheme, so the existing static API (`Style.Color.background`, etc.) keeps working everywhere untouched:

```swift
// pattern — use for every token
static let background = SwiftUI.Color(UIColor { trait in
    trait.userInterfaceStyle == .light
        ? UIColor(hex: "F4F3F0")
        : UIColor(hex: "111112")
})
```

Add a small `UIColor(hex:)` initializer next to the existing `SwiftUI.Color(hex:)` one.

Appearance selection: store the user's choice in `@AppStorage("kebab.appearance")` with values `"light"` / `"dark"`, **default `"dark"`** (current behavior is dark; nothing changes for existing users until they touch the toggle). In `kebabApp.swift`, apply `.preferredColorScheme(storedAppearance == "light" ? .light : .dark)` at the root so the dynamic colors resolve app-wide. No per-view changes.

## 2. Token values

Replace the current values in `Style.Color` with these:

| Token (existing name) | Light | Dark (current value being replaced) |
|---|---|---|
| `background` | `#F4F3F0` | `#111112` (was `#171718`) |
| `primaryText` | `#161718` | `#F0EFEC` (was `#CAD0DB`) |
| `secondary` | `#8B8A86` | `#84837F` (was `#575B61`) |
| `separator` | `#E7E5E1` | `#232324` (was `#262727`) |
| `composerBackground` | `#FFFFFF` | `#1A1A1B` (was `#282828`) |
| `composerSend` | `#161718` | `#F0EFEC` (was `#935ED5` — **purple is retired**) |
| `destructive` | `#C42B44` | `#FF6478` (was `#DD2340`) |
| `resurface` | `#D9822B` | `#F0A868` (was `#FFC57C`) |
| `fire` | `#E36D9A` | `#F49CC0` (was `#F79CE1`) |
| `stickyNoteYellow` | `#EBCF47` | `#EBCF47` (unchanged — same in both modes) |

Add two **new** tokens:

| New token | Light | Dark | Used for |
|---|---|---|---|
| `composerSendForeground` | `#FFFFFF` | `#111112` | the arrow glyph inside the send circle (it currently uses `primaryText`, which breaks when the send fill becomes ink/bone) |
| `linkAccent` | `#2AA2FF` | `#2AA2FF` | link-card title text + link glyph tint — the single "azure moment" per screen; use it ONLY where link UI currently uses `primaryText` for tint |

Design intent, for your judgment calls: this is the "Greige & Azure" system — warm near-neutral surfaces, ink as the action color (the send button is a black pill in light mode, bone in dark), azure spent exactly once per screen on links, and the amber/pink counters as the only other color. Nothing else in the UI should be saturated.

## 3. Hardcoded color sweep

Several views bypass `Style.Color` with literals. Migrate them to tokens **without changing what role the color plays**:

- `AuthView.swift`: `.white` text/icons → `primaryText` where on `background`; the white primary CTA capsule → `composerSend` fill with `composerSendForeground` label (it's the same "primary action" role); `.foregroundColor(Style.Color.background)` on CTA labels follows automatically.
- `ComposerView.swift`: the `UIColor(red: 202/255, green: 208/255, blue: 219/255, ...)` text color in `GrowingTextView` → dynamic equivalent of `primaryText`. The send-button arrow → `composerSendForeground`. The mic recording tint currently uses `composerSend` — keep the token, it now reads as ink, which is correct.
- `EntryRowView.swift` / `SearchResultRowView.swift` / link cards (`RichLinkCardView.swift`, `LinkCardView.swift`): underlined link-title text and link glyphs → `linkAccent`.
- Any `Color.black.opacity(0.4)` overlay scrims: keep as-is (they work over both modes).
- The glass composer tint (`composerBackground.opacity(0.5)`) keeps its token — no change needed.

Search the whole target for `Color(hex:`, `.white`, `.black`, and `UIColor(red:` to catch stragglers; map each to the token matching its role. If a literal has no clear role, leave it and list it in your summary rather than guessing.

## 4. Appearance toggle in Settings

In `SettingsView`, add one row between the email container and the log-out container, styled identically to the existing rows (same `composerBackground` fill, corner radius 16, same padding constants):

- Left: label `Appearance` in the same font/color as the email row text.
- Right: a compact two-option control — `Light` / `Dark` — reflecting and writing `@AppStorage("kebab.appearance")`. A simple `Picker` with `.segmented` style is fine for now, or two small tappable text buttons where the active one uses `primaryText` and the inactive uses `secondary`. Match the app's typography (DM Sans, existing sizes); no new fonts, no icons required.
- Switching should animate the scheme change smoothly (the `preferredColorScheme` change at root handles it; wrap the AppStorage write in `withAnimation(.easeInOut(duration: 0.25))`).
- Light haptic on change (`Haptics.lightTap()`).

## 5. Explicitly out of scope

- No layout, spacing, or component changes anywhere.
- No changes to LaunchScreen.storyboard, the app icon, or the launch wordmark assets.
- No new screens, no renamed files, no dependency changes.
- Do not touch entry logic, view models, or repositories.

## 6. Acceptance checklist

1. App builds and runs; default appearance is dark and looks like the current app but warmer (soot `#111112` walls, bone text, ink→bone send button, azure link titles).
2. Toggling to Light in Settings flips every screen — feed, entry detail, comments, search, composer, auth, collection sheets, action sheets, edit overlays — with no unreadable text anywhere. Spot-check: placeholder text on composer, secondary meta text, separators visible but quiet, link cards legible.
3. `resurface` amber and `fire` pink counters read clearly in both modes.
4. No view file shows structural diffs — color and the one Settings row only.
5. Grep confirms no remaining hardcoded UI colors outside `Style.swift` (except deliberate scrims listed in your summary).

When done, give me a summary of every file touched and any literal you left in place.

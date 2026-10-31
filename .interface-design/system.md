# iMessage Bridge: interface system

Native macOS settings app (SwiftUI, `Form` + `.formStyle(.grouped)`), sidebar
navigation. It should look like a well-made System Settings pane rather than a
custom-themed app. The reference implementation is `Sources/IMessageBridgeApp/SafetyView.swift`.

## Direction

- **Organize by what happens, not by feature.** Section titles describe a
  moment in the message's path: "Before an agent reads a message", "Before an
  agent sends a message". Avoid vendor or mechanism names as section titles
  ("Prompt injection", "Detection").
- **One summary card at the top of a page** says whether the user is protected,
  in one sentence, with the evidence underneath (stats, then a visual path).
  If the page is in a bad state, the card says what to do next.
- **No master switches.** A capability is on when at least one of its parts is
  on and usable. Each part has its own toggle. Settings that only matter while
  the capability is on are hidden while it's off.
- **Progressive disclosure.** Rarely changed options (model names, provider
  details) live in a sheet behind "Settings…", and within that behind an
  "Advanced" disclosure.

## Depth and surfaces

- System grouped-form surfaces only. No custom shadows, gradients or card
  backgrounds; the summary card is just the first `Section`.
- Separation comes from `Section`s and the form's own row dividers.
- Color carries status only: green = on/protected, orange = warning, unprotected
  or a failed check, red = a flagged message or a hard error. Everything else is primary/secondary/tertiary label colors.

## Type

| Role | Style |
| --- | --- |
| Summary headline | `.title3.weight(.semibold)` |
| Summary subtitle / stats | `.callout`, secondary |
| Row title (CheckRow) | `.body.weight(.semibold)` |
| Row detail, footers, notes | `.callout`, secondary |
| Plain setting labels | default `.body` (via `Toggle`/`Picker`/`LabeledContent`) |
| Grid column heads | `.caption.weight(.medium)`, secondary |
| Numbers that change | `.monospacedDigit()` |

## Spacing

- Rows: let `Form` handle it. Custom rows add `.padding(.vertical, 4)`.
- Summary card: `.padding(.vertical, 6)`.
- Sheets: 20pt outer padding, fixed width (480 for a settings sheet).
- Icon column: 28pt wide, so titles line up across rows.

## Components

### CheckRow
A part of a capability that can be turned on separately (e.g. "On this Mac", "Jev").

- Leading SF Symbol, `.title3`, secondary, in a 28pt-wide column.
- Title (semibold body) over a one- or two-sentence detail (callout secondary)
  that says what it catches and what it costs (money, privacy, RAM).
- Trailing controls, right-aligned: secondary actions first ("Settings…", a
  `⋯` `Menu` for Update/Remove), then the `Toggle` (`.labelsHidden()`) last.
- When it can't be used yet, the trailing control is the one action that makes
  it usable ("Download", "Add API Key…") instead of a toggle. In-progress
  states (download progress, "Installing…") replace the controls in place.

### FlowStrip
A horizontal picture of the path a message takes: endpoint icon → chips → endpoint icon.

- Chips are capsules, 9pt horizontal / 4pt vertical padding, `.callout.weight(.medium)`.
- On: green text, `Color.green.opacity(0.12)` fill.
- Off: tertiary text, faint fill, 1pt dashed tertiary border.
- The actor (the agent) is neutral: primary text, semibold, no status color.
- Separators: `chevron.right`, `.caption2.weight(.semibold)`, tertiary.
- `ViewThatFits`: labels + icons, then icons only (labels move to `.help`).
- One combined accessibility label listing every step and its state.

### Summary card
- Leading 28pt status symbol (`checkmark.shield.fill` green / `shield.lefthalf.filled` orange).
- Headline states the outcome ("Incoming messages are screened" / "...aren't screened").
- Subtitle: session stats when on; otherwise the single next step.
- FlowStrip underneath; a transient error (orange callout with a warning symbol) last.

### Settings sheet
- Header row: symbol + title (title3 semibold) + one-line explanation.
- Segmented picker for a choice of 2–3 providers.
- Fields, then toggles that depend on the choice, then a "Get a key" link.
- `DisclosureGroup("Advanced")` for anything most people never change.
- A single "Done" button (default action); changes save as they're made.

### Test results grid
`Grid` with sample names down the side and one column per check; each cell is
a symbol + short word, `.callout`: Flagged (red shield), Passed (secondary
checkmark), Error (orange triangle). The check's note is the `.help` tooltip.

## Copy

- Plain language, second person, no jargon in titles ("On this Mac", not
  "Local classifier"). Name the technology in the detail line, with required
  attribution ("Built with Llama").
- Segmented options ordered least → most aggressive (Relaxed, Balanced, Strict),
  with a one-line subtitle saying the tradeoff.
- Footers state limits honestly ("Screening is an alarm, not a guarantee.").
- Menu items that act immediately have no ellipsis; ones that open UI do.

## Implementation constraints

- The toolchain is the Command Line Tools only: the `@State` macro plugin is
  unavailable. Keep view state in an `ObservableObject` held by `@StateObject`
  (`@Published` properties), as `SafetyModel` and `JevSheetModel` do.
- Screenshots for the website come from `IMessageBridgeApp --screenshots <dir>`
  (`Screenshotter.swift`); regenerate them after visual changes and copy into `docs/images`.

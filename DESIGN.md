# DESIGN.md — Jarvis Desktop Companion

## Color
- Base: near-black blue veil over the desktop, oklch(0.13 0.02 230) at ~92% alpha.
- Primary hologram cyan: oklch(0.82 0.10 220) (#6fd3ff family). Carries lines, rings, labels.
- Dim cyan (hairlines/inactive): the same hue at 30-40% alpha. Never pure grey.
- Alert amber: oklch(0.80 0.12 70) (#ffb454 family). Due items, warnings, listening state.
- Text: oklch(0.93 0.02 220) (#dff3ff family). Never #fff.
- Status colors used only in instruments (jobs constellation, rings), never as decoration.

## Typography
- Face: Bahnschrift (Light for display, regular for body). Fallback: Segoe UI.
- Display (greeting): 30-36px, weight 300, tracking 0.12-0.16em.
- Body/instrument labels: 13-16px.
- Micro-labels: 9-11px uppercase, tracking 0.25-0.35em, dim cyan.
- Numerals in instruments: tabular feel, generous size against tiny labels (contrast ≥ 2x).

## Space & layout
- Full-bleed overlay; content floats in space, no cards, no containers, no borders-as-boxes.
- Instruments anchor to screen regions: time-things left, money right, focus center-upper,
  command line lower-center. Corners carry fine brackets.
- Hairlines: 1px at 25-40% alpha cyan. Nothing thicker than 3px except the orb.

## Motion
- Entry: staggered reveal, translate+blur to sharp, 500ms, cubic-bezier(0.22, 1, 0.36, 1).
- Ambient: one slow radar sweep, ring rotations 20-60s linear. Nothing else moves at rest.
- Interactive feedback under 200ms. Exponential ease-out only. No bounce.
- prefers-reduced-motion: all ambient motion off.

## Components
- Micro-label: uppercase, tracked, dim. Sits above or beside its value, never bold.
- Chip (reply key-phrase): hairline border, pill, transparent fill, quiet inner glow.
- Instrument ring: thin track at low alpha + value arc in primary cyan with small glow.
- Command line: bare underline input, chevron prompt, no box.

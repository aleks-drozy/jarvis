# TASTE.md - your Jarvis's design judgment (template)

Copy to `{{VAULT}}\TASTE.md` and adapt. This file keeps visual/UX decisions coherent as the app
evolves - it records WHY things look the way they do, so changes answer to a rationale instead of
drifting on vibes. Loaded alongside SOUL.md when present.

## Visual
- Resting color / meaning of each state color (the stock app: cyan = idle, amber = listening; a
  state is a color change, never a popup).
- Real data only on screen: if a number is decorative theatre, it goes.
- Respect prefers-reduced-motion; animation is garnish, never information.

## Language on screen
- Chips/HUD text is telegraph (a few words); the spoken line carries the sentence. Timestamps and
  sources beat adjectives.

## Notifications & sound
- One channel per event (a silent Telegram push does not also chime the desktop).
- Failure alarms may be blunt and ugly on purpose.

## The three questions for any new surface
(1) real data? (2) follows the state colors above? (3) would the briefing's voice phrase it this way?
Any "no" means redesign before shipping.

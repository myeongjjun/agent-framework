# Agent office art
Original work drawn for this repo, no third-party assets.
Hand-written SVG geometry; no brand logos, borrowed mascots, fonts, or external references.
Palette: cream #f4efe6, paper #fffdf7, ink #2a2520, wood #b98a5e / #8f6440.
Strokes: rounded 2–2.5px ink contours; solid offset shadows; transparent backgrounds.
Claude: orange #e07a52, soft domed head and swept forelock, rounded chair.
Codex: navy #34507a, chamfered head, side modules and inset visor, angular chair.
Working: raised head, open eyes, lifted typing hands, green illuminated laptop.
Idle: lowered head, closed eyes, resting hands, dark laptop; identity colours stay visible.
Reception: amber #e0a020 waistcoat, headset, wide counter and service bell.
Human: warm skin, swept brown hair, red shirt and tall rose upholstered swivel chair.
Workers (64×64): claude-working.svg, claude-idle.svg, codex-working.svg, codex-idle.svg.
Seats: desk-agent.svg (96×64), user.svg (64×64).
Notes (40×32): note-msg.svg (blue bubble), note-report.svg (amber check seal).
Notes (40×32): note-input.svg (red keyboard), note-new.svg (purple arrival sparkle).
Badges (24×24): badge-user.svg (red !), badge-desk.svg (amber ?); all marks are paths.
Preview: open preview.html locally; every asset appears at native 1× and enlarged 2×.
Dependencies: none; no uv installation or build step is needed for these static assets.
Validation: parse SVG XML, check viewBoxes and sizes (<4 KB), then review preview.html.

## Power
Token use is shown as light: each worker's bulb is drawn by the page; the power card is text.
Batteries: battery-0.svg through battery-4.svg (32×16), empty red tip to four green cells — what is left of a plan's limit.

## Role props
A worker that runs as an agent definition (a committee member pane, or `claude --agent X`) gets a 40×40 prop on its desk.
Props are not in this repo: the office server asks Codex for missing ones (`art_step` in `cmux/brief`, one `sib spawn --codex` pane at a time, each role at most once a day).
The pane gets `task.md` with this style and the role's description, writes `<role>.svg`, and is closed once every file passes the check.
Check: SVG XML with a viewBox, 4 KB or less, no text, image, style, script, foreignObject, external URL or event attribute.
Accepted props live in `~/.local/share/cmux/office-art/<role>.svg` (one machine's set); jobs and their task files stay under `jobs/`.

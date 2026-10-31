# <Project> design

Visual reference for the product. Visual work is designed here before it is built: UI features that cite it must reproduce it, adapted to the app's real components and tokens.

## What is here

| Path | What it is |
|---|---|
| `system/README.md` | Brand guide: principles, voice and copy, colour, type, spacing, icons, logo, motion and accessibility. |
| `system/tokens.json` | Exact token values per theme (colours, type, spacing, radii, shadows). Colour names are the app's CSS variables without `--`. |
| `system/components/*.md` | Guidelines for the base components. |
| `screens/<Screen>.dc.html` | One screen (and the feature that builds it, e.g. "Settings (F097)"). |

## How to read a `.dc.html`

They are plain HTML files with inline styles, and those styles are the spec (sizes, colours, type and spacing). Besides:

- `<sc-if value="{{ x }}">` is a conditional block (e.g. a form and its confirmation).
- `<dc-import name="X">` embeds the sibling file `X.dc.html`.
- `{{ value }}` is a state value. The final `<script type="text/x-dc">` only holds that demo logic.
- `support.js` is the design editor's runtime. Ignore it.

Colours: in the app, every colour is written with its theme variable, never as a literal. Mapping: `#…` is `--bg`, `#…` is `--text`, … (fill it in). If a screen declares variables at its root (`--bg: …`), the rest already uses `var(--…)`, as in the app. Photos and avatars in the mock-ups are illustrative.

If your designs come from another tool (Figma exports, screenshots, HTML mock-ups), replace this section with how to read them.

## Editable originals

The originals live in <tool and links>. When they change, this folder is updated through a change (`loopkit/prompts/CHANGE.md`).

# Diagrams

The diagram at the top of the README is drawn with [Archify](https://github.com/tt-a1i/archify) (Apache-2.0),
tested with v3.2.0.

| File | What it is |
|---|---|
| `how-it-works.archify.json`, `how-it-works.es.archify.json` | The source (English / Spanish). Edit these. |
| `how-it-works.html`, `how-it-works.es.html` | Interactive version: one self-contained file, works offline. Download and open it in a browser. |
| `how-it-works-light.svg`, `how-it-works-dark.svg` (and `.es.svg`) | Static images used by the README, light and dark. |

To regenerate after editing a source (needs Node 18+ and Chrome or Chromium; Archify installed as a skill):

```bash
TYPE=$(jq -r .diagram_type docs/diagrams/how-it-works.archify.json)
node <archify>/bin/archify.mjs finalize "$TYPE" docs/diagrams/how-it-works.archify.json docs/diagrams/how-it-works.html --quality showcase
```

Then open the HTML, use **Export → SVG · Light** and **SVG · Dark**, and save them over the two `.svg` files.
`finalize` also writes a `*.delivery.json` receipt with local paths; do not commit it.

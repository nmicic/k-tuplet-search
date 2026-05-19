# visualizations/ - browser-side analysis tools

This directory contains standalone visualization and exploration assets.

## Tools

| Path | Purpose |
|---|---|
| `k-tuplet-analyzer/index.html` | Interactive k-tuplet pattern analyzer |

## Usage

Open the HTML file directly in a browser:

```bash
xdg-open visualizations/k-tuplet-analyzer/index.html
```

If `xdg-open` is unavailable, open the file manually from your browser. The
visualization is static HTML/JavaScript and does not require a local server.

## Notes

The analyzer is a convenience UI for understanding forbidden residues,
admissibility, and pattern structure. Use the engine catalog and
`tools/patterns/` scripts for generated machine-readable data.

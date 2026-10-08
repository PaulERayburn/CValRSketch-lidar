# CValRSketch

**Free, open-source floor-plan sketching for residential appraisers.** Sketch by typing or speaking wall lengths, or import an iGUIDE PDF; get GLA and below-grade totals and print-ready sketches. Everything runs in your browser — your sketches never leave your machine.

**▶ Use it now:** [Desktop](https://caa-ebv-co-op.github.io/CValRSketch/) · [Phone](https://caa-ebv-co-op.github.io/CValRSketch/m/) · [Download the latest release](https://github.com/CAA-EBV-CO-OP/CValRSketch/releases/latest)

![CValRSketch desktop app with the sample house open: main floor, garage, deck and porch, with wall lengths, areas and the basement panel](docs/screenshot.webp)

**Version:** 0.44.3 (2026-10-08) · **License:** [AGPL-3.0](./LICENSE) · **Part of:** [OSASI — the Open Source Appraisal Software Initiative](https://osasi.org)

Want a new feature? [Request it](https://github.com/CAA-EBV-CO-OP/CValRSketch/issues), or build it yourself — see [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## Overview

Walk the perimeter by entering distances and directions — typed, spoken, or clicked on a compass — and the app draws the plan, labels every wall, totals the areas above and below grade, and exports a print-ready sketch. Or start from an iGUIDE floor-plan PDF and let it trace every floor for you.

It needs no installation, no server and no account: a static web page with plain HTML, CSS and JavaScript and no build step. Sketches are saved and loaded as JSON files on the local machine. **Save app copy** (header) writes a frozen, self-contained HTML of the running version — keep it in the job folder beside the sketch so the sketch reopens the same way years later (works from a served copy such as osasi.org; a copy opened from disk cannot read its own source).

Developed for the CAA-EBV-CO-OP community as part of [OSASI](https://osasi.org), the Open Source Appraisal Software Initiative — a co-operative of real estate appraisers building shared, open tools that run entirely in the browser.

### Why CValRSketch

CValRSketch began as a stop-gap when the desktop sketch software many of us relied on fell behind on support. It grew into a full sketching tool built by appraisers, for appraisers: quick to learn, free to use, and open, so it keeps working and keeps improving no matter what happens to any one vendor.

To try it with something already drawn, load [`docs/sample-house.json`](./docs/sample-house.json) (a made-up house) with **Load** in the app.

---

## Quick Start

### Desktop (Chrome / Edge / Firefox / Safari)
- **Online:** open **https://caa-ebv-co-op.github.io/CValRSketch/** — nothing to install; it also works offline once loaded.
- **Your own copy:** download the [latest release](https://github.com/CAA-EBV-CO-OP/CValRSketch/releases/latest) (or clone this repo) and open `index.html`. Everything works from disk except **Import PDF**, which needs the page served: run `python -m http.server` in the folder and open `http://localhost:8000/`.
- Press **F1** (or **❓ Help**) in the app for a guide that follows whatever you are doing.

### Mobile (iPhone / Android) — touch-first version

A dedicated mobile-first page lives at **`m/index.html`**, optimised for one-thumb operation: direction pad + numeric keypad, pinch-zoom canvas, share-sheet exports. Use it on your phone instead of the desktop page.

Live URL: **https://caa-ebv-co-op.github.io/CValRSketch/m/**

To install it as a home-screen icon:

1. Open the URL above on your phone in **Chrome (Android)** or **Safari (iOS)**.
2. **Android:** Chrome surfaces an "Install" / "Add to Home screen" prompt automatically.
3. **iOS:** tap the Share button → **Add to Home Screen**.
4. Launch from the home-screen icon — opens full-screen, no browser chrome.

Sketches save and load as JSON and are interchangeable between the desktop and mobile pages.

### Install the desktop version on a phone (PWA, advanced)

If you specifically want the desktop UI on your phone (with its three-column layout — usually not what you want on a small screen), the same install steps work on the root URL **https://caa-ebv-co-op.github.io/CValRSketch/**.

Service workers do not run on `file://`, so PWA install requires hosting. For local testing, run any static server (e.g. `python -m http.server` in the repo folder) and open `http://localhost:8000/`.

Everything runs in the browser: plain HTML, CSS and vanilla JavaScript, nothing sent anywhere. The one third-party library, Mozilla PDF.js (Apache-2.0), is kept in `vendor/pdfjs/` and loaded only when you import a PDF.

---

## How It Works

1. Pick a start point (defaults to origin).
2. Enter wall segments in the **New Segment** box. Format: `<length> <dir> [angle]`. Examples:
   - `40'3 l` — 40 feet 3 inches left
   - `16'4 u 45` — 16'4" angled 45° right from the previous heading
   - `5'd 2'l` — diagonal wall with components 5' down and 2' left
3. Close the shape when the path returns to the start point. The gap indicator shows the directional offset if the shape is not yet closed.
4. Label the area (e.g. Living, Finished Basement, Open Deck) — square footage is calculated automatically.
5. Add floors (Basement / Main / Upper) as needed. Other floors render as adjustable-opacity ghosts.
6. Set a Subject (e.g. a property address) for the export title.
7. Export as SVG or PNG, optionally fitted to US Letter portrait or landscape.

---

## Features

### Drawing
- **Walk mode** — enter segments as `<length> <dir> [angle]` (e.g. `16'4 u`, `26'9 r`, `8 d`)
- **Relative angle turns** — `r 45` turns 45° right of the previous heading; `l 45` turns 45° left
- **Combined-component diagonals** — `5'd 2'l` creates one diagonal wall from directional components
- **Auto-extend** — enter a direction alone (e.g. `r`) to preview the next aligned vertex
- **Pen-jump** — arrow keys move the pen to the next aligned vertex without drawing a wall
- **Sub-measurements** — `37'6+2'9 l` sums to 40'3"
- **Batch entry** — comma-separated segments: `16'4 u, 26'9 r, 8 d`
- **Gap diagnosis** — open shapes display a directional breakdown (e.g. `gap 5'5" (2'0" left + 5'0" down)`)

### Editing
- **Edit mode** — select any wall or vertex to modify length, move, insert, delete, or curve a wall into an arc by its rise
- **Image mode** — load a scanned plan, set it to scale from two known points, and trace over it — by typing walls, or by clicking its corners with a magnifier (lengths worked out from the scale)
- **Length-edit modes** — stretch end, symmetric, maintain rectangle
- **Split mode** — divide a shape with a projected wall
- **Fence (group stretch)** — drag a selection rectangle; enclosed vertices translate, crossing walls stretch
- **Copy shape with offset** — duplicate a selected shape at a typed offset (e.g. `10' r`)

### Measurement Annotations
- **Measure tool** — 📏 Measure (or M), then click any two points: corners and walls snap, Alt for a free point, Shift for level/plumb; labeled measurements belong to their floor and persist across save/load

### Multi-Floor
- Floors: Basement / Main / Upper (rename or add as needed)
- Ghost view of other floors at adjustable opacity (5%–100%), with labels and dimensions
- Per-floor totals and grand totals by area type

### Export
- SVG and PNG with optional subject title and legend
- Legend built from area types in use, with per-type square footage totals and wall-style key
- Page sizes: Auto, US Letter Portrait (8.5×11"), US Letter Landscape (11×8.5")
- Tight crop — bounding box of actual content, not the full canvas
- Title and legend rendered at full size regardless of sketch scale
- UI overlays (selection handles, fence rings, vertex pickers) are stripped from exports

### Import a floor-plan PDF
- **📐 Import PDF…** reads an **iGUIDE** floor-plan PDF and creates one shape per floor, traced from the PDF's vector drawing (not a picture), so corners land within about half an inch
- A check table compares each traced floor with the area iGUIDE states; floors go to the matching tab, multi-building plans arrive as separate buildings
- Rooms iGUIDE excludes (garage, unheated sun room) come in as their own areas, sized to the excluded area it states; decks, porches and patios are traced from the outline around their label
- Each floor is turned and slid to sit over the main floor (wall directions, the page compass, then walls landing on walls); placements that are a judgment call are flagged *check position*
- Runs on your computer: the PDF is never uploaded. Needs the hosted app (or any local web server); a page opened straight from disk cannot load the PDF reader
- New formats are added as *format profiles* in `pdf-import.mjs`

### Basement and buildings
- Basement panel: below-grade area and % finished per building; the area follows the main floor unless you type one
- **Match basement to main floor** — replace a scanned or walked basement outline with the main floor's (at import, in Edit on the basement tab, or in the Basement panel)
- Named buildings (house, cabin, shop…) in one file, with an *All* gallery; **Add files…** merges sketches as buildings

### Help
- **❓ Help** (or `F1` / `?`) — a floating panel that follows the mode or tool you are using; pick the topics you want shown; pin it to keep it open while you draw
- Action links in Help outline the real button and use it, so you learn where everything lives

### Other
- **Zoom and pan** — mouse wheel or pinch zooms about the cursor, middle-drag (or ✋) pans, *Fit* resets; exports always print the whole plan
- Undo / Redo (`Ctrl+Z` / `Ctrl+Y`)
- Save / Load as JSON
- Subject field persists with the sketch
- Square footage displayed as whole numbers

---

## Notes

- Runs entirely client-side. No data is transmitted externally.
- No build pipeline: `index.html` (desktop), `m/index.html` (phone), `core.js` (shared logic), `pdf-import.mjs` (PDF import, loaded on demand). The legacy `sketch_walker.html` redirects.
- Tested in Chromium-based browsers and Firefox. Safari is expected to work but is less tested.
- On touch devices use the phone page (`m/`); the desktop page has no touch gestures.
- Third-party code: PDF import uses Mozilla [PDF.js](https://github.com/mozilla/pdf.js) (Apache-2.0), vendored unmodified in `vendor/pdfjs/` and loaded only when a PDF is imported.

---

## License

Released under the [GNU Affero General Public License v3.0 (AGPL-3.0)](./LICENSE).

You may use, modify, and redistribute this software. Modified versions — including network-deployed instances — must remain under AGPL-3.0 with source available.

What that means in practice:

- **Use it freely.** Anyone may run, study and modify CValRSketch, personally or commercially.
- **Share alike.** If you redistribute it, modified or not, you must provide the complete corresponding source under AGPL-3.0. If you modify it and let others use it over a network (a hosted copy), those users must be offered the source too (AGPL §13).
- **Keep the notices.** The copyright, licence and no-warranty notices in `NOTICE`, the file headers, and the About dialog must stay with every copy; modified files must say they were changed and when (AGPL §5).
- **Credit is required, not optional.** Under additional terms adopted per AGPL §7(b) and §7(c) (see `NOTICE`; the licence text itself is `LICENSE`), every copy and every derivative must preserve and display the attribution *"Built on CValRSketch, an OSASI project — https://osasi.org"* wherever it shows its own name, version or legal notices, and a modified version must not be presented as the original or as endorsed by OSASI or CAA-EBV-CO-OP.

**Your own branding is welcome.** Settings → *Your branding* takes your firm name and logo (kept in your browser, not in sketch files) and puts them in the app header and the title block of every export; the *provided by osasi.org* credit on exports is off unless you tick it. Beyond that you may restyle the app and even rename it — the licence permits modification, and the exported sketch pages carry no required notice at all, so client-facing output is entirely yours. Two things stay: the attribution *Built on CValRSketch, an OSASI project* remains wherever the app shows its own name, version or legal notices (the About dialog is enough), and a rebranded version must not be presented as the original or as endorsed by OSASI. If you share or host your branded version for others, the same source-sharing rule applies to it.

The names *CValRSketch* and *OSASI* are not licensed for use on derivative works in a way that suggests endorsement; please rename your fork if it diverges.

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Issues and pull requests are welcome.

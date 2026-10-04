# LiDAR import — working plan

This fork (`PaulERayburn/CValRSketch-lidar`, branch `feature/lidar`) explores reading a phone or tablet LiDAR scan into CValRSketch the way `pdf-import.mjs` reads an iGUIDE PDF: one area per floor, accurate enough to stand in for tape measurements. Finished pieces go back to `CAA-EBV-CO-OP/CValRSketch` as pull requests.

## The appraisal problem to solve

A LiDAR scan is taken **inside** the house, so it measures **interior** walls. Gross living area is figured from **exterior** dimensions. The importer therefore has to:

- find the outer ring of rooms (the building's envelope), not every room;
- push that ring outward by the exterior wall thickness (a setting, e.g. 6" for 2×6 framing plus finishes), with a per-wall override for thicker foundation walls; the result should be checked against at least one exterior tape measurement;
- keep garages, decks and other non-living spaces as separate areas, as the iGUIDE import does.

## Field workflow: either order (decided 2026-10-04)

**Both orders must work: measure outside first, or scan inside first.** The scan imports on its own (inside first), and the overlay compares whichever came second with whichever came first. The order below is the one Paul usually uses.

Outside first follows the appraiser's normal order: greet the occupants, measure the outside first to see what the job involves, go inside **once**, then go back outside only if something is still missing. Going outside twice is fine; going back inside is intrusive and should never be needed.

1. **Outside:** sketch the exterior in CValRSketch as now (walk, laser, speech-to-text or typed), as completely as the site allows. Sides that can't be reached (shrubs, fences) are left as not measured.
2. **Inside, one visit:** scan with CValRScan, share the scan into CValRSketch on the same phone, and let CValRSketch lay it over the exterior sketch. Before leaving, it gives a **"before you leave" list**:
   - exterior sides with no laser reading that the scan doesn't reach either ("scan the living-room back wall from inside");
   - missing walls in the scan (gaps, typically closets), to fill with **Mark wall** or a laser depth;
   - anything a second floor still needs.
3. **Outside again, if needed:** only for what the comparison flags.

What each source is for:

- **The laser sketch is the source for GLA**, as it is today.
- **The scan fills and checks it:** it supplies sides that couldn't be reached outside (interior faces plus wall thickness), checks the sides that were lasered, and gives the room layout and upper floors.
- **Wall thickness is measured, not assumed:** where a side was measured outside and scanned inside, the difference is that wall's real thickness, used for sides seen only from inside. The 6″ setting is the fallback.
- **Fitting needs no AR tie-in:** the scan's outline is slid and turned to best fit the lasered sides (most houses are all square corners). The AR outside walk in CValRScan stays optional, for sides that can be walked but not lasered.

Decisions:

- The exterior sketch stays in CValRSketch; CValRScan does not get its own sketching.
- The on-site comparison and the "before you leave" list live in CValRSketch, where the importer and the sketch already are. CValRScan stays a scanner.
- CValRSketch needs a way to mark an exterior side as **not measured** (couldn't reach), so the comparison knows which sides the scan must supply. To be designed with the project owner, as it touches the main app.

## Candidate sources (to be confirmed with real exports)

| Source | What it likely gives | Effort |
|---|---|---|
| Apple RoomPlan exports (from apps built on it) | Walls, doors, windows as straight segments with sizes | Low: already vectors |
| Scanner apps' own floor-plan export (DXF, SVG or PDF) | A 2-D plan, possibly already dimensioned | Low–medium: one format profile per app |
| Raw point cloud (PLY, LAS, E57, OBJ mesh) | Millions of points, no walls | High: slice at wall height, fit lines, square up |

The order to work in: take one real export from Paul's phone, see which of these it is, and build that profile first.

**Own capture app (in progress, Mac only).** `ios/CValRScan/` is a small RoomPlan app that exports a plain JSON plan (`cvalrscan`, described in `ios/CValRScan/README.md`). It gives the importer a format we control, with no USDZ or point-cloud library needed. Third-party exports stay a second option.

## How it fits the app

- A lazy-loaded module (`lidar-import.mjs`), like `pdf-import.mjs`, with format profiles as data so a new app's export is added as a profile, not new code.
- Output is ordinary shapes (`points`, `floor`, `type`), so every existing tool (Split, Remove wall, corner dragging, Ctrl squaring, basement matching) works on the result.
- Runs in the browser on the user's own device; scans never leave it.
- Any new runtime dependency (e.g. a USDZ/zip or point-cloud reader) needs the project owner's approval first (CLAUDE.md §8).

## Steps

1. ~~Scan a room or two of a house you own and inspect the export.~~ Done: CValRScan's own `cvalrscan` format (now version 4).
2. ~~Write `lidar-import.mjs` to read a `cvalrscan` file into CValRSketch shapes, one area per floor.~~ Done: **Import PDF or scan…** reads it through the PDF import window. On the 2026-10-04 scan of Paul's house: 894 sf inside the walls, 989 sf outside, with thickness measured on 14 of 16 sides from the outside walk. Still to check against a tape measurement.
3. **Overlay on an existing sketch:** fit the scan's outline to the lasered exterior sides, measure wall thickness from sides measured both ways, and fill sides measured only from inside.
4. Produce the **"before you leave" list** on the phone (unreached sides, scan gaps, upper floors).
5. ~~With no exterior sketch, fall back to the scan alone.~~ Done in step 2: this is the inside-first path.
6. ~~In the importer, split any outside-walk wall~~ Done in step 2: split any outside-walk wall whose points turn a corner (a missed **Next wall**), as the app now offers to on site: split where two fitted lines give the least total squared error, repeat while any part is more than 6″ off its line.

## Public-repo rule

This fork is public. Test scans, file names and notes must not identify a client property: no addresses, job numbers or listing photos. Use your own house or a made-up sample.

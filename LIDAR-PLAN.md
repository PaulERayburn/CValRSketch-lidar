# LiDAR import — working plan

This fork (`PaulERayburn/CValRSketch-lidar`, branch `feature/lidar`) explores reading a phone or tablet LiDAR scan into CValRSketch the way `pdf-import.mjs` reads an iGUIDE PDF: one area per floor, accurate enough to stand in for tape measurements. Finished pieces go back to `CAA-EBV-CO-OP/CValRSketch` as pull requests.

## The appraisal problem to solve

A LiDAR scan is taken **inside** the house, so it measures **interior** walls. Gross living area is figured from **exterior** dimensions. The importer therefore has to:

- find the outer ring of rooms (the building's envelope), not every room;
- push that ring outward by the exterior wall thickness (a setting, e.g. 6" for 2×6 framing plus finishes), with a per-wall override for thicker foundation walls; the result should be checked against at least one exterior tape measurement;
- keep garages, decks and other non-living spaces as separate areas, as the iGUIDE import does.

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

## First steps

1. Scan a room or two of a house you own (not a client's) with whatever LiDAR app you would use in the field, and export every format it offers.
2. Inspect the files: which source above is it, what units, does it separate floors?
3. Write the first profile, import the test scan, and compare it with tape measurements.
4. Add the interior → exterior wall-thickness step and test it on a whole floor.

## Public-repo rule

This fork is public. Test scans, file names and notes must not identify a client property: no addresses, job numbers or listing photos. Use your own house or a made-up sample.

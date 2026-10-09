# CValRScan — LiDAR capture for CValRSketch (iOS)

A small iPhone/iPad app built on Apple's RoomPlan. It scans a house room by room and shares a plain JSON floor plan that `lidar-import.mjs` can read without any new library.

It lives only in the `PaulERayburn/CValRSketch-lidar` fork for now. Adding an `ios/` folder to the main repo is an architectural change and needs the project owner's approval first (CLAUDE.md §1, §8).

## Requirements

- A Mac with Xcode (iOS apps cannot be built on Windows).
- An iPhone 12 Pro or later Pro model, or an iPad Pro with LiDAR, on iOS 17 or later.
- An Apple Account signed into Xcode; a free account can install the app on your own device.

## Using it

1. **Scan a room**, walk slowly along the walls, then **Done with room**. Repeat for every room on every floor without closing the app: the rooms share one AR session, so they line up. In dark closets use the **flashlight**. Where coats or shelves hide a wall, aim at any bare spot on it (above the shelf, between hangers, low behind shoes) and tap **Mark wall**: one point per hidden wall. A brown dot stays where each point landed, with its distance shown; the floor, ceiling and shelves are refused.
2. **Go outside** (optional): set a start spot by the door, mark 2+ points on the siding of each outside wall (**Next wall** at each corner), come back in and **Check start spot** to measure tracking drift. If a wall's points turn a corner (more than 6″ off one line), the app offers to split them into separate walls.
3. **Build floor plan** merges the rooms (RoomPlan's `StructureBuilder`) and saves the scan in the app, with the AR world map so it can be **resumed on site** later. It also checks for **missing walls**: floor edges with nothing scanned along them, typically a closet back hidden by coats.
4. **Measure walls → Edit** cleans up the scan: tap a stray wall to delete it, drag a wall's end (square handle) to move it, snapping to corners and to square; tap a brown hidden wall to remove the point or depth behind it. **Rooms**: tap a room to name it (2-pc bath, laundry, closet, entry…) or a name to change or remove it. **Doors**: tap a wall to add an entrance door, interior door or opening; tap an added one to remove it. **Undo** and **Restore scan** take edits back.
5. **Measure walls** shows missing walls in red. Tap one to fill it: resume and **Mark wall** on site, or enter a laser depth from the scanned wall facing it (blue). Filled gaps turn grey and the hidden wall is drawn in brown. Then readings: the app asks for a reading after **Build floor plan** and suggests the longest outside wall (purple) until one is entered. Tap a wall, say where you stood (a room, or outside), enter the laser reading face to face, and choose which end wall may move to fit it. Where no single scanned wall covers the stretch (RoomPlan splits an outside wall where rooms meet inside), tap **Corners**, then the two corners: outside readings run siding corner to siding corner. Readings add and subtract, for a wall lasered in pieces: `11 11 + 6 5 + 6 2`, or `30 0 − 5 6` (a minus needs spaces round it, so `10-6` is still 10′ 6″).
5. **Share scan files** sends two files (AirDrop, Files, email):
   - `scan-<date>.cvalrscan.json`: the plan CValRSketch reads (below).
   - `scan-<date>.capturedstructure.json`: RoomPlan's full output.
   - `scan-<date>.usdz`: a 3-D model (walls with door and window openings, furniture as boxes) that Files, Quick Look and AR open on any iPhone or Mac. **View in 3D** shows it in the app on a plain background (turn, zoom, move); opening the shared file in Files gives Apple's viewer with AR.

Saved scans are listed on the home screen and in the Files app under On My iPhone → CValRScan. File names carry only a timestamp. Scan your own house for testing: this fork is public.

## `cvalrscan` format, version 7

Top-down plan. Lengths in **metres**, except readings, which are whole inches as entered. Plan `x` is world x and plan `y` is world z, so +y points down the page like CValRSketch's world coordinates.

```json
{
  "format": "cvalrscan", "version": 7, "units": "m",
  "createdAt": "2026-10-03T15:00:00Z",
  "walls":    [{ "id": "…", "story": 0, "a": [x, y], "b": [x, y], "height": 2.44, "bottom": -1.2, "wall": null, "curved": false }],
  "doors":    [{ "…same fields…", "wall": "<parent wall id>" }],
  "windows":  [ … ],
  "openings": [ … ],
  "floors":   [{ "id": "…", "story": 0, "elevation": -1.2, "polygon": [[x, y], …] }],
  "sections": [{ "label": "bedroom", "story": 0, "center": [x, y] }],
  "corners":  [{ "point": [x, y], "elevation": -0.3 }],
  "wallPoints": [{ "point": [x, y], "elevation": 0.4, "normal": [nx, ny] }],
  "gaps":     [{ "story": 0, "a": [x, y], "b": [x, y] }],
  "gapDepths": [{ "gap": [[x, y], [x, y]], "from": "<wall id>", "inches": 24 }],
  "wallEdits": [{ "wall": "<id>", "hidden": true }, { "wall": "<id>", "hidden": false, "a": [x, y], "b": null }],
  "spans":    [{ "a": [x, y], "b": [x, y], "story": 0, "inches": 294, "face": "outside", "entered": "11 11 + 6 5 + 6 2" }],
  "measurements": [{ "wall": "<id>", "walls": ["<id>", …], "inches": 129, "face": "inside", "side": 1,
                     "room": "Bedroom", "move": "auto", "moving": ["<id>"], "entered": "10 9" }],
  "exterior": { "walls": [[{ "point": [x, y], "elevation": 0.4 }, …], …],
                "anchorStart": { "point": [x, y], "elevation": 1.1 }, "anchorEnd": { … } }
}
```

- `a`/`b` are a wall's end points at floor level. `bottom` and `elevation` are world heights, so a window's sill height is `bottom - elevation` of its story's floor.
- `story` numbers floors as RoomPlan does (0 is the floor where scanning began).
- `curved: true` marks a curved wall; `a`/`b` are then its chord. The full curve is in the `capturedstructure` file.
- Walls between rooms are stored **once, as a single line with no thickness**; both rooms measure to it. Outside walls belong to one room and sit on their inside face.
- `corners`: scans before version 4 only (**Mark corner**, since retired: marks aimed into corners landed 2–4 ft off).
- `wallPoints`: points on walls the scan missed, from **Mark wall**: the hit and the wall's horizontal facing. The importer sets that wall square to the house (along whichever main direction is nearer the facing) through the point.
- `gaps`: floor-outline stretches over 30 cm with no wall, door, window or opening within 15 cm: walls the scan missed.
- `gapDepths`: laser depths across a gap, from the gap-side face of scanned wall `from` (whose line is taken as the wall's centre, so add half a partition), square across to the hidden wall.
- `wallEdits`: scanned walls the user deleted or whose ends they dragged in **Measure walls → Edit**; already applied to `walls`, kept so the app can undo them.
- `roomLabels`: room names the user gave, or (`replaces`, with an empty name to remove) changed from the scan's `sections`. `rooms`: every name as it stands, for the importer.
- `addedOpenings`: doors and openings the user added (`kind` entrance, interior or opening); also included in `doors` (with `type`) and `openings`.
- `spans`: readings between two scanned corners `a` and `b` (the inside corners as scanned), along the house's main direction. `face` `outside` is siding corner to siding corner; `inside`, face to face. `entered` is the reading as typed, e.g. a sum of pieces.
- `measurements`: laser readings, always face to face; `entered` is the reading as typed. `face` is `inside` or `outside`; `side` is +1 for the side the normal (−dy, dx) of the wall's a→b points to, −1 for the other; `walls` lists every scanned segment the reading spans; `moving` names the end walls that may shift to honour it (`move` records whether that was the user's choice or `auto`).
- `exterior`: the outside walk. Points per outside wall in the order taken; `anchorEnd − anchorStart` is the tracking drift over the walk, to be spread over the points in order.

### What RoomPlan does not give

RoomPlan measures **interior** faces only. It does not report wall thickness or which walls are exterior. Finding the outer ring and pushing it out to exterior dimensions stays in the importer, as `LIDAR-PLAN.md` describes, checked against a tape measurement.

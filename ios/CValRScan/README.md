# CValRScan — LiDAR capture for CValRSketch (iOS)

A small iPhone/iPad app built on Apple's RoomPlan. It scans a house room by room and shares a plain JSON floor plan that `lidar-import.mjs` can read without any new library.

It lives only in the `PaulERayburn/CValRSketch-lidar` fork for now. Adding an `ios/` folder to the main repo is an architectural change and needs the project owner's approval first (CLAUDE.md §1, §8).

## Requirements

- A Mac with Xcode (iOS apps cannot be built on Windows).
- An iPhone 12 Pro or later Pro model, or an iPad Pro with LiDAR, on iOS 17 or later.
- An Apple Account signed into Xcode; a free account can install the app on your own device.

## Using it

1. **Scan a room**, walk slowly along the walls, then **Done with room**. Repeat for every room on every floor without closing the app: the rooms share one AR session, so they line up. In dark closets use the **flashlight**. Where coats or shelves hide a wall, aim at any bare spot on it (above the shelf, between hangers, low behind shoes) and tap **Mark wall**: one point per hidden wall. A brown dot stays where each point landed, with its distance shown; the floor, ceiling and shelves are refused.
2. **Go outside** (optional): set a start spot by the door, mark 2+ points on the siding of each outside wall (**Next wall** at each corner), come back in and **Check start spot** to measure tracking drift. If a wall's points turn a corner (more than 6″ off one line), the app offers to split them into separate walls. Points are measured with the LiDAR depth: stand close (a narrow side yard is fine) and face the siding. Under the crosshair the app shows the distance and how far off square you are: green within 12 ft and 30°, orange up to 16 ft and 50°, red beyond, when **Mark point** is off and says why. Each mark fits the strip of siding across the middle of the screen, so a downpipe or shrub in it doesn't matter. With LiDAR one point is enough for a short wall (a bay, a jog, a chimney chase): it carries the wall's direction. **Mark corner**: stand back a few feet from a corner of the house so both faces of siding show either side of the crosshair (an inside corner works too); when the readout says `Corner · 4.1 ft · 92°`, tap it. The corner ends the wall you were on and starts the next, as Next wall would, so walking corner to corner needs no other taps. If it can't see two faces meeting it says why ("Only one wall in view — aim at the corner", "Faces don't meet at a corner"). A line above the buttons says how the wall is doing ("Wall 3 · 1 point — step along 3 ft for another, or Mark corner", "Wall 3 · 2 points ✓") and, when the crosshair has turned onto another wall, "New wall? Tap Next wall or Mark corner". **Undo** after a corner takes it off both walls. A **volume button** marks a point too, so does a Bluetooth selfie-stick remote: a double beep for a good mark, a low beep when refused (the beeps follow the ring/silent switch).
**Photos.** The camera button (scanning a room, and on the outside walk once the start spot is set) saves a photo pinned on the plan where the phone stood, facing the way it looked. **Wide photo (0.5×)**, from 0.27.0, uses the ultra-wide camera for a whole room or elevation in one shot. ARKit tracks with the 1× camera only, so the wide photo pauses the AR session (nothing is reset), shows the ultra-wide picture with a shutter and **Cancel**, then runs the session again. It is on the home screen between rooms (**Wide photo (0.5×)**, under Remove last room) and as **0.5×** beside the camera button outside; while a room is being scanned RoomPlan has the camera, so **0.5×** there just says to tap Done with room first. Phones without an ultra-wide camera don't show it. Stand still while it's up: afterwards the app waits for tracking to settle (up to 5 s) and compares where the phone is with where it was when you tapped. More than 4″ (10 cm) and it warns *Tracking moved 7″ while the wide camera was up*: check the orange dots still sit on the siding (outside), or point the phone at a scanned room and move it slowly before the next room. If tracking doesn't come back it says to move the phone slowly around until it settles. The photo is pinned where you stood when you tapped, saved like any other photo (and with the unbuilt scan, in case the app closes), and turned upright by how the phone was held at the shutter.

3. **Build floor plan** merges the rooms (RoomPlan's `StructureBuilder`) and saves the scan in the app, with the AR world map so it can be **resumed on site** later. It also checks for **missing walls**: floor edges with nothing scanned along them, typically a closet back hidden by coats.
4. **Measure walls → Edit** cleans up the scan: tap walls to select them, then **Align** (one straight line through them, squared to the house within 10°; joined walls follow) or **Delete**; drag a wall's end (square handle) to move it, snapping to corners and to square; tap a brown hidden wall to remove the point or depth behind it. **Rooms**: tap a room to name it (2-pc bath, laundry, closet, entry…) or a name to change or remove it. **Doors**: tap a wall to add an entrance door, interior door or opening; tap any door or opening, the scan's included, to change its type (entrance, interior, opening), width (common widths or any typed one), style (swing, pocket, bifold, sliding) and which way it opens, or remove it. Doors are drawn with their swing or style symbol; openings in dashed purple. **Undo** and **Restore scan** take edits back.
5. **Measure walls** shows missing walls in red. Tap one to fill it: resume and **Mark wall** on site, or enter a laser depth from the scanned wall facing it (blue). Filled gaps turn grey and the hidden wall is drawn in brown. Then readings: the app asks for a reading after **Build floor plan** and suggests the longest outside wall (purple) until one is entered. Tap a wall, say where you stood (a room, or outside), enter the laser reading face to face, and choose which end wall may move to fit it. Where no single scanned wall covers the stretch (RoomPlan splits an outside wall where rooms meet inside), tap **Corners**, then the two corners: outside readings run siding corner to siding corner. Readings add and subtract, for a wall lasered in pieces: `11 11 + 6 5 + 6 2`, or `30 0 − 5 6` (a minus needs spaces round it, so `10-6` is still 10′ 6″). **Bluetooth laser:** a Huepar S-series laser (it shows up as `LDM-…`) or a Bosch GLM-C (e.g. GLM165-27C; turn its Bluetooth on) fills readings in directly. Only one at a time: the app takes the first it finds. Tap **Connect laser** under a reading once, and it reconnects whenever the app opens. Each press of the laser's measure button enters the distance to the nearest inch; a second press adds it as another piece (`+`), and a gap depth takes the latest press. The laser sends metric whatever its screen shows, so its units setting doesn't matter. Keep its reference point at the back, for face-to-face readings. **Clear last** takes the last piece off a reading (a press that went wrong or twice); **Clear all** empties it. Where an end of the wall turns away from where you stand (a jog), measure to the corner edge in line with that wall: at a jog the inside and outside readings come out the same, and a wall reading is checked against a Corners reading of the same stretch from the other side, when there is one.
5. **Share scan files** sends two files (AirDrop, Files, email):
   - `scan-<date>.cvalrscan.json`: the plan CValRSketch reads (below).
   - `scan-<date>.capturedstructure.json`: RoomPlan's full output.
   - `scan-<date>.usdz`: a 3-D model (walls with door and window openings, furniture as boxes) that Files, Quick Look and AR open on any iPhone or Mac. **View in 3D** shows it in the app on a plain background (turn, zoom, move); opening the shared file in Files gives Apple's viewer with AR.

**If the app closes before Build floor plan** (a crash, iOS closing it in the background, a flat battery), nothing is lost. From 0.26.0 the scan is saved as you go: after every room, Remove last room, outside point, corner, Next wall, start spot and photo, into a folder `inprogress-<id>` beside the saved scans (the rooms, the marks, the outside walk, photos and name; the AR session, about 100 MB, after each room and otherwise every 5 minutes). On the next launch the home screen offers it at the top, e.g. *Recover unfinished scan — 6 rooms, 8 photos, 11:15 AM*:
- **Recover** puts the scan back as it was. **Build floor plan** works straight away. To scan more rooms or go outside, first **Resume on site** (as for a saved scan), so the new rooms line up; if the AR session wasn't saved, it says so and the scan can be built but not resumed.
- **Discard** (asks first) deletes the unbuilt rooms and marks. Photos are never deleted: they move to a folder named `Recovered photos <date> <time>` in Files, or, for a scan that continued a saved one, stay with it.
- **New** on an unbuilt scan, or **Scan a room** while one is waiting to be recovered, asks first; a scan kept for later is offered again.

Build floor plan removes the scan's `inprogress-` folder once the scan files are written.

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
  "exterior": { "walls": [[{ "point": [x, y], "elevation": 0.4, "method": "lidar", "distance": 1.42, "angle": 12.5,
                              "rms": 0.006, "n": 3120, "camera": [x, y], "dir": [dx, dy], "span": [[x, y], [x, y]] }, …,
                            { "point": [x, y], "elevation": 0.5, "kind": "corner", "method": "lidar-corner", "dirs": [[dx, dy], [dx, dy]],
                              "angle": 90.4, "rms": 0.008, "n": 4210, "distance": 1.3, "camera": [x, y] }],
                           [{ "…the same corner…" }, …], …],
                "anchorStart": { "point": [x, y], "elevation": 1.1 }, "anchorEnd": { … } },
  "photoFolder": "photos-1a2b3c4d",
  "photos":   [{ "file": "photo-3-1760281200.jpg", "point": [x, y], "elevation": 1.3, "facing": [dx, dy],
                 "takenAt": "2026-10-12T15:00:00Z", "outside": false, "fullRes": true, "wide": true }]
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
- Doors in `doors` carry `hinge` ("a" or "b"), `side` (+1 the normal (−dy, dx) side of a→b, −1 the other; for the scan's own doors, into the floor) and `style` (swing, pocket, bifold, sliding).
- `addedOpenings`: doors and openings the user added (`kind` entrance, interior or opening); also included in `doors` (with `type`) and `openings`.
- `spans`: readings between two scanned corners `a` and `b` (the inside corners as scanned), along the house's main direction. `face` `outside` is siding corner to siding corner; `inside`, face to face. `entered` is the reading as typed, e.g. a sum of pieces.
- `measurements`: laser readings, always face to face; `entered` is the reading as typed. `face` is `inside` or `outside`; `side` is +1 for the side the normal (−dy, dx) of the wall's a→b points to, −1 for the other; `walls` lists every scanned segment the reading spans; `moving` names the end walls that may shift to honour it (`move` records whether that was the user's choice or `auto`).
- `exterior`: the outside walk. Points per outside wall in the order taken; `anchorEnd − anchorStart` is the tracking drift over the walk, to be spread over the points in order. From 0.24.0 each point also says how it was found (absent in older scans; all optional): `method` `lidar` is the LiDAR depth of the siding strip across the screen fitted as one upright plane, the point being where the crosshair meets it; `plane` is ARKit's estimated plane (devices without depth), which on plain siding at a slant can land a foot or more off. `distance` (m) from the phone and `angle` (degrees off square) at the moment of marking; `camera` where the phone was. For `lidar` only: `rms` (m) of the fit, `n` depth samples in it, `dir` the fitted wall's run (unit, plan) and `span` the strip's ends on that line, so one point carries the wall's direction too. `camera` and `span` have had the drift folded in with `point` when a scan is resumed. From 0.25.0, `kind` `corner` (method `lidar-corner`) is a marked corner of the house: two upright planes fitted to the siding either side of the crosshair, the point being the vertical line where they meet, at the crosshair's height. It is the last point of the wall it ends and, identical, the first of the wall it starts (the walk's final corner may be a wall on its own); count it once when spreading the drift. `dirs` are the two faces' runs (unit, plan), each pointing away from the corner along its face (the face's samples all lie that way); `dirs[0]` is the wall it ends (the face the wall's earlier points lie along; with none, the face on the left of the screen) and `dirs[1]` the wall it starts. For a corner, `angle` is the angle between the faces (90 for a square corner) and `rms`, `n` cover both faces. The importer takes a wall of one LiDAR point as a line along its `dir` over its `span`, and each corner as 1.5 ft of each face out from it; corners never split a wall.

- `photos`: photos taken during the scan, JPEGs in the folder `photoFolder` (shared as `<name> <date> photos.zip`). `point`/`elevation` is where the phone was, `facing` the level direction it looked (unit, plan). `fullRes` is false for a video frame (when the session couldn't give a full still). From 0.27.0, `wide: true` marks a 0.5× ultra-wide photo; it is absent for the others. The photo was taken after the pin was recorded, with the AR session paused, so the pin is where the user stood when they tapped Wide photo.

### What RoomPlan does not give

RoomPlan measures **interior** faces only. It does not report wall thickness or which walls are exterior. Finding the outer ring and pushing it out to exterior dimensions stays in the importer, as `LIDAR-PLAN.md` describes, checked against a tape measurement.

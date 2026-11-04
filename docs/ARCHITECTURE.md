# Architecture - FrameSheet

## System Overview

FrameSheet v3 is a Swift package with a UI-free core library and a SwiftUI
app. The core holds the document model, the layout math, persistence and
the decode layer; the app holds the window, the views and the app state. v2
(`src/`, a `swiftc`-only build) was removed with the v3 skeleton and stays
at tag v2.3.1.

```mermaid
graph TD
    V[SwiftUI views] --> M[AppModel @MainActor]
    M -->|Library edits, selection| L[Library model]
    M -->|save / load JSON| S[LibraryStore]
    M -->|open movie| R[DecoderRouter]
    R -->|default| AV[AVFoundationBackend<br/>AVAssetImageGenerator, VideoToolbox]
    R -->|no decodable track, hev1| FF[FFmpegBackend<br/>system ffmpeg/ffprobe]
    M -->|discover ffmpeg| FL[FFmpegLocator]
    AV --> C[ThumbnailCache LRU]
    FF --> C
    C --> V
    V -->|layout| G[GridGeometry]
```

## Package layout

```
Package.swift                    Swift 6, macOS 27, arm64
Sources/FrameSheetCore/          no SwiftUI or AppKit
├── Models.swift                 Library, MovieFile, Sheet, Thumb, Scene,
│                                Settings, Defaults (all Codable)
├── IntervalFrames.swift         mapRange + getIntervalArray (MoviePrint),
│                                sheet naming, timecode
├── GridGeometry.swift           grid part of MoviePrint getScaleValueObject
├── LibraryStore.swift           JSON in Application Support
├── Editing/
│   ├── EditHistory.swift        50-step undo/redo; EditableLibrary.edit
│   ├── IntervalEditing.swift    thumb and sheet operations, interval scenes
│   ├── Scrub.swift              pointer → frame mapping, scrub actions
│   ├── GridLayout.swift         optimized columns, stats line, zoom, frame info
│   └── ThumbNavigation.swift    next/previous thumb, dimming, scrub layout
├── Export/
│   ├── FileNaming.swift         [MN] [ME] [SN] [FN] [TC] templates, " edit N"
│   ├── PNGText.swift            tEXt chunks before IEND, CRC32
│   ├── SheetExchange.swift      MoviePrint-compatible PNG/JSON data, import
│   ├── PrintHeader.swift        header lines, mini timeline, metrics
│   ├── PrintOutput.swift        output size and max, decode width, 8-bit encoding
│   ├── IncomingFiles.swift      route PNG/JSON to import, the rest to movies
│   └── EDLExport.swift          CMX3600 EDL of a shot sheet (MoviePrint)
├── Scan/
│   ├── ShotScanner.swift        one sequential pass (AVAssetReader output
│   │                            provider or an ffmpeg BGRA pipe), events
│   ├── ShotMetrics.swift        HSV, Mean and Histogram metrics, vImage 240 px
│   ├── RawVideoPipe.swift       ffmpeg rawvideo reader
│   ├── ScanCache.swift          per-movie Float32 difference + color, resumable
│   ├── AutoInOut.swift          black head and tail detection
│   └── DetectionChart.swift     histogram and k-means threshold (display)
├── Player/
│   ├── PlayerNavigation.swift   steps, cut and thumb jumps, frame from time
│   ├── FrameStripGeometry.swift strip slices, timeline bars, scene bars
│   ├── PlayerEditing.swift      cut/merge and change/add at a frame
│   └── FFmpegPlayback.swift     video-only ffmpeg playback pacing
├── Faces/
│   ├── FaceAnalyzer.swift       FaceAnalyzer protocol, Vision face rectangles
│   ├── FaceScanner.swift        face scan on the scan pass, analysis workers,
│   │                            thumbnails from the scanned frames
│   ├── FaceCache.swift          per-movie face cache, stale scan cleanup
│   └── FaceSheetSource.swift    a faces sheet's scope and thresholds (Apply)
├── TimelineGeometry.swift       timeline rows, px per frame, scene boxes
├── PathDisplay.swift            ~/… for paths under home
└── Decode/
    ├── DecodeBackend.swift      protocol, MediaInfo, DecodedFrame, errors
    ├── AVFoundationBackend.swift  probe, zero-tolerance thumbs + ±0.5 s retry
    ├── FFmpegBackend.swift      ffprobe probe, packet-scan duration,
    │                            one input-seeking ffmpeg run per frame (×5)
    ├── DecoderRouter.swift      AVFoundation first, ffmpeg fallback
    ├── FFmpegLocator.swift      user path → login shell → known directories
    ├── ProcessRunner.swift      shell-free Process with timeout/cancel
    └── ThumbnailCache.swift     LRU cache limited by pixel bytes (256 MB)
Sources/FrameSheet/              the app
├── FrameSheetApp.swift          Window scene, menus, AppDelegate, key monitor
├── AppModel.swift               @Observable state over an EditableLibrary:
│                                edits, selection, zoom, scrub, thumbnail
│                                loading, debounced saving, import, relink
├── AppModel+Save.swift          Save sheet, Save thumb, each thumb, Export JSON
├── AppModel+Scan.swift          shot scans from the app: stream, cancel, resume
├── AppModel+Scenes.swift        scene actions: cut, merge, jump to cut
├── DetectionChartView.swift     the detection chart (F)
├── PlayerView.swift             the player view (key 2)
├── PlayerController.swift       AVPlayer or ffmpeg playback, stills, strip runs
├── AppModel+Player.swift        player entry points and edits at its frame
├── AppModel+Faces.swift         face scans, faces sheets, sort, filter, Apply
├── ScanLog.swift                scan timings to ~/Library/Logs/FrameSheet/scan.log
├── PrintView.swift              the print (header, thumbs, frame info), drawn
│                                in the window and by ImageRenderer for saving
├── ContentView.swift            split view, inspector, title and sidebar
│                                toggle, drop target, toast
├── SheetToolbar.swift           sheet tools in the window toolbar
├── MovieListView.swift          movie rows, sheet rows, context menus, Locate
├── SheetGridView.swift          grid, thumbs, hover overlay, frame info,
│                                reorder, placeholder rows
├── ScrubOverlay.swift           scrub overlay with neighbours and Cancel bar
├── SettingsPanel.swift          right panel: grid, styling, frame info
├── SettingsWindow.swift         Settings (⌘,): thumbnail cache, ffmpeg
└── Theme.swift                  kni tokens, system fonts, panel and toolbar styles
Tests/FrameSheetCoreTests/       swift test (Swift Testing)
assets/AppIcon.png               build.sh → .icns
tools/spike/                     separate measurement package
```

## Core model

`Library` is the whole document: movies in list order (`MovieFile`, with a
bookmark, probe data, IN/OUT, transform, scan state and a sheet counter),
sheets per movie (`Sheet`: type, view, columns, seconds per row, parent,
thumbs, scenes), global `Settings`, and the selection. Sheet names are
`Sheet-N` from the per-movie counter (libraries before version 2 have their
`MoviePrint-N` names renamed on load). Interval sheets take N frame
numbers evenly between IN and OUT with MoviePrint's own rounding. The app
mutates the library on the main actor and saves it as JSON half a second
after each change; it is loaded once on launch. Settings decode with defaults
for missing keys so later versions can add fields.

## Editing

Every user-visible edit goes through `AppModel.edit`, which runs a `Library`
operation inside `EditableLibrary.edit`: the library before the edit becomes
one undo step (50 kept, not persisted), and the change is saved and its new
frames decoded. Selection, zoom and global settings change without an undo
step. The operations follow MoviePrint: insert takes the frame midway to the
visible neighbour, IN/OUT recapture the visible count between the new limits,
Expand makes a child sheet over the thumb's interval scene (scenes split at
the midpoints between visible thumbs) whose id is the thumb's id, and the
scrub maps the pointer between the neighbours (Shift, Option and Control
change the range; the first and last thumb extend to the movie's ends). The
scrub decodes at display size with one request in flight and the latest
position next; release applies the exact frame as one undo step.

## Decoding

Movies open through `DecoderRouter`: AVFoundation first; the file goes to
ffmpeg when AVFoundation has no video track, the track is not decodable, or
the HEVC sample entry is `hev1` (VideoToolbox rejects it although the track
claims to be decodable). Frames are addressed by number. AVFoundation asks
for the middle of a frame's display interval with zero tolerance and retries
a failure once with ±0.5 s, reporting the frame actually decoded (decision
11); the app then moves the thumb to that frame. The ffmpeg path seeks half a
frame early, takes the first frame from a PNG pipe, five runs at a time in
software decode, and retries 0.5 s earlier when the frame count estimated
from the duration runs past the last frame.

Shot scans read the movie once in order (`ShotScanner`): 720 px BGRA through
the `AVAssetReader` output provider (or an ffmpeg rawvideo pipe for files
routed to ffmpeg), 240 px via vImage, and MoviePrint's Mean or Histogram
difference per frame. The scan holds `DecodeGate` and, when thumb requests
wait, closes its reader, lets them through and reopens at a closed-GOP sync
sample, running at least four times as long as the last reopen took. The
per-frame differences and colors go to a resumable cache in Application
Support; scenes come from it with MoviePrint's
`calculateSceneListFromDifferenceArray`, so a new threshold needs no rescan.
About 710 fps on a 1080p H.264 file (9 min for a 2 h film), lower while thumbs
load.

The player's frame strip asks `frameRun(_:maxWidth:)` for the missing frames
of its 20-frame window: one `AVAssetReader` pass from a closed-GOP sync sample,
then one ffmpeg rawvideo run for what is left (with the exact-frame option),
then single frames; slices are cached by frame. A step costs 60–90 ms on an
open-GOP film with short GOPs and about 250–280 ms on a 1080p H.264 file with
4 s GOPs (the reader starts at the previous keyframe). Playback holds
`DecodeGate` for as long as AVPlayer (or the ffmpeg pipe) plays, so no other
decode runs beside it; paused frames are exact stills through decision 25.

Face scans run Vision face rectangles on the scan pass's 720 px frames (the
shot scan's combined pass when the shot scan has not read them, a faces-only
pass otherwise): sampled frames are copied into a pooled buffer and handed to
two analysis workers through a 6-frame backlog with back-pressure; results are
committed in frame order, so a cancel leaves a consistent prefix to resume
from. Frames with faces also give the faces sheet's thumbnails, so the sheet
needs no further decodes. Measured on an open-GOP 24 fps film (17620 frames,
every 10th frame): 18.8 s in the app on a quiet Mac, the same as the shot scan
alone; Vision overlaps two requests (about 1.6× the single throughput), and a
remote-screen app sharing the GPU and media engine slowed the same scan to
33 s. Window thumbs are decoded at their drawn size (128–640 px), so a
400-thumb faces sheet fits the 256 MB cache.

Near the end of a movie the retry window is moved inside the movie (center at
most end − 0.5 s). A file whose sync samples are open-GOP I frames decodes
only partly with AVFoundation (KNOWN_ISSUES 5), so a frame the generator
misses goes through `EarlierGOPReader` (an `AVAssetReader` from the previous
sync sample) and then, with the Settings option on, `FFmpegFrameFallback`
(decision 25); every `DecodedFrame` names its decoder and whether it is exact,
and the app marks inexact thumbs and refuses an inexact scrub. The ffmpeg path
seeks a little early and picks the frame by its pts (`select` + `showinfo`), so
it is frame-exact, including leading B frames. `ThumbnailCache` is a
least-recently-used cache that drops images only past its byte limit (an
`NSCache` dropped them under memory pressure, so other sheets redrew).

## Saving and import

`PrintView` draws the print once for both the window and the saved file: the
window adds its interaction layer (hover, selection, placeholders, drag) on
top. Save sheet decodes the print's frames fresh at twice the output thumb
width (capped at the movie width) in small sequential batches through
`DecodeGate`, renders with `ImageRenderer` (standard dynamic range), converts
to 8-bit sRGB and encodes off the main actor; a PNG gets MoviePrint's `tEXt`
chunks (`version` "FrameSheet x.y.z", `filePath`, `transformObject`,
`columnCount`, `frameNumberArray`, `sceneArray`). Import reads those chunks
or the JSON export (also MoviePrint 0.2.x files), adds a new movie entry and
sheet, probes the movie and keeps the frame numbers. Every way files enter
(Add movies, drop, Import Sheet…, Open With) goes through
`AppModel.openFiles`, which sends PNG and JSON to import.

ffmpeg is found in the order of §10 (user path, login-shell `command -v`,
known directories), each candidate validated with `ffmpeg -version`;
`ffprobe` must sit next to it.

## Display

Views use the kni Design System through `Theme`: Catppuccin Mocha surfaces
(base, mantle, crust) with 1 pt borders, the accent for selection only, and
the system fonts (SF Pro, SF Pro Condensed, SF Mono; owner, 2026-11-03).
Hover buttons follow MoviePrint (faint white over the thumb, solid white over
the button, condensed text sized from the thumb). `GridGeometry` reproduces
MoviePrint's grid sizes (thumb width = movie width × 0.25, separate horizontal
and vertical margin ratios, corner radius ratio, header height) and scales the
print to fit the main area at the current zoom (0.25 … 8), with fill-height
and fill-width zooms. Rows in the panel are a target only: extra rows show as
placeholders, fewer rows dim the thumbs past columns × rows, and Replace
recaptures. Thumbs are decoded at 640 px wide (posters at 320 px) into
`ThumbnailCache`; the current sheet's and the posters' images are also pinned
outside the cache so eviction cannot start a reload loop, and a reload of the
same image waits at least 2 s. All AVFoundation decodes pass one `DecodeGate`
(one at a time), after two kernel panics in the hardware decoder driver under
many parallel sessions (2026-11-02, 2026-11-03); raising it is pending a
per-machine measurement.

## Dependencies

No bundled binaries and no packages. `ffmpeg`/`ffprobe` are optional, needed
only for files AVFoundation cannot decode.

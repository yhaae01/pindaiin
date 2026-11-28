# Pindaiin — Document Scanner & File Super App

A local-first Flutter MVP: scan multiple pages, adjust each one, export to PDF or
images, manage the results in a file hub, and convert between images and PDFs.
All file processing happens on the device.

## Features

**Scanner**
- Live preview scanning: incoming camera frames are analysed a few times per
  second and the detected page outline is drawn over the preview in real time.
- Capture pages with the shutter (always available) or turn on auto-capture
  when the detected quad is stable. Pages accumulate in the batch; the system
  camera remains a fallback when the in-app camera cannot open.
- Automatic document edge detection: the paper sheet is found, the page is
  perspective-warped (deskewed) and everything outside it — desk, hands,
  surroundings — is cropped away. Captures are taken at full photo resolution,
  not from the preview frames.
- Adjust edges: a zoomed preview with four draggable corner handles, so a
  missed or low-contrast detection can be fixed right after an uncertain
  capture (offered in the live scanner) or later from the batch editor.
- Batch editor: reorder by dragging, rotate left/right, fine-crop with corner
  handles, apply Original / Grayscale / Document filters, and re-adjust the
  perspective from the untouched original at any time. The thumbnail strip has
  a quick-actions menu per page (rotate left/right, recrop, delete) so a sheet
  can be fixed without selecting it first.
- Export the batch as one multi-page PDF (quality presets) or one JPG/PNG per
  page. Exported files are registered in the file hub immediately, then shown
  in a summary with name, size, page count, rename, Share, Open and Done.

**File hub**
- History of every exported/converted file with search, rename, preview, share,
  "open with", and delete. Filter chips switch between All, Scans, PDFs and
  Converted; every row has a one-tap Share button in addition to the overflow
  menu.
- In-app preview: zoomable images and a full PDF reader (page swiping,
  zoom, jump slider, metadata, Share/Open and Edit).
- Metadata persisted in Hive; bytes live in app-private storage.

**Converter**
- Images (JPG/PNG/WebP) → PDF: fully offline.
- PDF → JPG images: fully offline.
- Office: DOCX/XLSX/DOC/XLS → PDF and PDF → DOCX/XLSX through an
  `OfficeConversionRepository`. Ships with a simulated demo backend and a REST
  client ready for a self-hosted renderer. Upload/download progress, validation
  (extension + 25 MB limit), timeouts and user-safe errors are handled.
- Every conversion ends in a result card with the output name, size, page
  count, Rename, Share (one or many files), Open and Done.

**PDF reader & editor**
- Reader: bounded-resolution page rendering with adjacent-page prefetch,
  pinch zoom, swipe/prev-next/slider navigation, a file-information sheet
  (size, pages, PDF version, metadata, encryption/tagging) and one-tap Share,
  Open and Edit.
- Page management: drag to reorder, rotate, and delete pages. Changes are
  pending until save; the source is never touched unless the user explicitly
  chooses **Overwrite original**.
- Markup: text boxes, rectangular highlights, freehand ink, and image/signature
  stamps. Colours and an undo-last-mark action are in the editor toolbar.
- Text replacement: search the real text layer, redact the old run and stamp the
  replacement at the same position. Scanned/image-only pages are detected and
  offer a PDF → DOCX conversion instead.
- Merge another PDF or extract selected pages into a new file. Every edit path
  registers its output in the File Hub and can be shared immediately.
- Password-protected PDFs prompt for a password; corrupt files show a retryable
  error instead of a blank screen.

## Project structure

```
lib/
├── main.dart                     # Hive init + bootstrap + runApp
├── app.dart                      # providers, MaterialApp, theme
├── core/
│   ├── document/                 # document scanning pipeline (pluggable)
│   │   ├── document_corners.dart       # normalized 4-corner page quad
│   │   ├── document_detector.dart      # DocumentDetector interface + result
│   │   ├── edge_document_detector.dart # Otsu mask → largest blob → quad
│   │   ├── luma_frame.dart             # grayscale camera frame value type
│   │   ├── live_scan.dart              # live config, update, smoothing/stability
│   │   ├── live_document_detector.dart # throttled isolate-backed live detector
│   │   ├── preview_mapping.dart        # frame → preview viewport/rotation math
│   │   ├── perspective_transform.dart  # 3x3 homography (unit square → quad)
│   │   ├── perspective_warper.dart     # PerspectiveWarper interface + warp
│   │   └── document_processor.dart     # facade: detect + warp by file path
│   ├── models/
│   │   ├── scanned_file.dart     # metadata model + JSON + FileKind/FileOrigin
│   │   ├── scan_page.dart        # page edits (rotation, crop, filter, source)
│   │   ├── pdf_edit.dart         # page refs, marks, text replacements
│   │   └── conversion.dart       # quality presets, modes, result types
│   ├── pdf/pdf_geometry.dart     # rotation-aware normalized ↔ PDF coordinates
│   ├── services/
│   │   ├── app_services.dart     # composition root (singletons + file registry)
│   │   ├── app_directories.dart  # app-private scans/exports/session folders
│   │   ├── file_storage_service.dart  # bytes, unique names, rename, delete
│   │   ├── file_repository.dart  # Hive box of JSON records (ChangeNotifier)
│   │   ├── file_access_service.dart   # camera, gallery, SAF picker, share, open
│   │   ├── image_processor.dart  # isolate export pipeline
│   │   ├── pdf_converter.dart    # images→PDF and PDF→images (pdf/pdfx)
│   │   ├── pdf_service.dart      # reader/editor engine: render, search, rewrite
│   │   ├── office_converter.dart # interface used by the conversion service
│   │   ├── office/
│   │   │   ├── office_conversion_models.dart      # target, progress, errors
│   │   │   ├── office_conversion_repository.dart  # repository abstraction
│   │   │   ├── rest_office_conversion_repository.dart  # Dio multipart client
│   │   │   ├── mock_office_conversion_repository.dart  # offline demo backend
│   │   │   └── repository_office_converter.dart   # validate + call + save
│   │   └── document_converter_service.dart  # validates and routes conversions
│   ├── theme/app_theme.dart
│   ├── utils/formatters.dart
│   └── widgets/
│       ├── scan_page_image.dart  # rotation/crop/filter preview painter
│       ├── live_quad_overlay.dart  # real-time contour/corner overlay
│       ├── document_quad_overlay.dart  # draggable 4-corner page handles
│       ├── crop_overlay.dart     # interactive crop handles
│       ├── result_summary_card.dart  # post-scan/convert summary + share/open
│       ├── rename_dialog.dart    # shared rename prompt
│       └── status_views.dart     # empty/error/busy states, dialogs
└── features/
    ├── home/home_shell.dart
    ├── scanner/                  # controller, capture screen, edge editor, batch editor, crop, sheets
    │   └── live_scan/            # live camera controller/screen + YUV/BGRA frame conversion
    ├── files/                    # controller, list, preview
    ├── pdf/                      # PDF reader + editor screens
    └── converter/                # controller, screen
```

The split keeps pixels (`services`), state (`controllers`) and UI (screens)
separate: no widget touches the filesystem or a plugin directly.

## Packages and why

| Package | Use |
| --- | --- |
| `provider` | Small, explicit `ChangeNotifier` wiring; no codegen. |
| `hive_ce` + `hive_ce_flutter` | Fast key/value metadata store. Community fork with current Flutter support. JSON strings avoid adapters/codegen. |
| `path_provider` | App-private `documents`/`cache` directories (scoped storage friendly). |
| `path` | Safe path joining and extension handling. |
| `camera` | Live preview, image stream for real-time edge detection, and high-resolution capture. |
| `image_picker` | System-camera fallback and multi-photo gallery import. |
| `file_picker` | System document picker for the converter (SAF on Android). |
| `image` | Decode/rotate/crop/filter/encode off the UI thread. |
| `pdf` | Writes merged multi-page PDFs with JPEG-compressed pages. |
| `pdfx` | Renders PDF pages for the converter's PDF → images path (platform PDFium). |
| `pdf_manipulator` | Native, off-main-thread PDF toolkit: metadata, text search, page reorder/rotate/delete, redaction, stamps, merge/extract. Used by `PdfService`. |
| `share_plus` | System share sheet for exported files. |
| `open_filex` | "Open with" for arbitrary file types. |
| `uuid` | Collision-free ids for files/pages/session folders. |
| `intl` | Timestamps used in names and list subtitles. |
| `dio` | Multipart upload with send/receive progress, timeouts and typed network errors for the Office backend. |
| `archive` | Builds valid minimal DOCX/XLSX placeholder files in the demo Office backend. |

## How key flows work

**Non-destructive editing.** A `ScanPage` stores `quarterTurns`, a crop `Rect`
normalized to the *rotated* page, and a filter. Rotating a page also rotates its
crop, so the visible region stays put. Nothing is re-encoded while editing.

**Live preview detection.** While the live scanner is open,
`CameraController.startImageStream` delivers preview frames.
`features/scanner/live_scan/camera_frame.dart` keeps only the luminance plane
(YUV420/NV21 on Android, BGRA8888 on iOS) and resamples it to ~400 px, so no JPEG
is decoded per frame. `LiveDocumentDetector` owns a long-lived worker isolate and
runs the same detector as still photos. At most one frame is in flight and
submissions are capped at 6 fps; extra frames are dropped rather than queued,
which is what keeps the preview smooth and the phone cool. Corners are rotated
into the displayed orientation (`preview_mapping.dart`) and smoothed by
`LiveScanTracker`, which marks the quad `stable` only after several consistent
frames — auto-capture waits for that flag. `LiveQuadOverlay` maps the quad through
the same `BoxFit.cover` geometry as the preview, so it stays on the paper at any
device rotation and screen size.

**Document capture and deskew.** Capturing a page goes through four stages:

1. **Detect** (`EdgeDocumentDetector`) — the photo is downscaled to 480 px, a
   luminance threshold (Otsu) separates the bright sheet from the background,
   the largest connected region is flood-filled, and the largest quadrilateral
   inscribed in its convex hull becomes the page outline. The result carries a
   confidence score instead of a hard yes/no.
2. **Confirm/adjust** (`DocumentEdgesScreen`) — a zoomed preview draws the four
   corners; drag a handle (a magnifier loupe appears so the finger never hides
   the edge) and reset, select the full image or rotate before confirming. The
   document filter is previewed live. It opens after every capture, so a
   confident detection is reviewed just like an uncertain one.
3. **Warp** (`HomographyPerspectiveWarper`) — the four corners define a
   projective transform from the output rectangle to the photo, so every
   output pixel is sampled bilinearly from the source. Lines stay straight,
   the page is deskewed, and the output size follows the measured page edges
   (capped at 2600 px for editing, 3000 px on export).
4. **Batch** — the straightened JPEG is written to the session folder and
   becomes the page image. Rotation, crop and filter stay non-destructive on
   top of it, and the untouched photo is kept in `ScanPage.sourceImagePath` so
   "Edges" can start over without compounding quality loss.

Gallery imports are straightened headlessly during import (uncertain pages are
left untouched). Live-scanner captures and system-camera photos are added
uncropped and open the edge editor with the detection already applied; only the
confirmed corners are warped. The batch editor's **Edges** tool reopens the same
editor for any page. The detector and warper only meet at `DocumentProcessor`,
constructed in `AppServices.bootstrap()` — swapping either interface changes no
widget or controller.

**Export pipeline** (`ImageProcessor`, in an isolate):
`bake EXIF orientation → downscale to ≤3000 px → rotate → crop → filter → encode`.
JPEG quality comes from the preset (45/70/90). PNG export skips quality but
still bakes all edits. A PDF is built from the rendered JPEG pages, so the PDF
matches the preview exactly.

**Sharing and opening.** `FileAccessService` is the only place that talks to
`share_plus`/`open_filex`. `shareFiles` checks that each path still exists and
is non-empty, attaches the extension's MIME type and returns a `ShareOutcome`
(shared count + skipped paths) or throws a `ShareException` with a snackbar-ready
message. The reusable `ResultSummaryCard` powers both the post-scan sheet and
the converter result, and the file hub calls the same service, so single-file,
multi-image and document sharing all follow one validated path. Opening is also
routed through the service, which maps `open_filex` failures to readable errors.

**Preview** (`ScanPageImage`): decodes at a bounded width, paints with
`Canvas.drawImageRect` using a source rect derived from the rotation
(90°/270° swap axes), plus a `ColorFilter.matrix` for Grayscale/Document.

**Sessions.** New pages are copied into a cache session folder. Cancelling a
scan deletes that folder; the user's originals are untouched. Only exported
files are registered in Hive.

**Converter.** `DocumentConverterService` validates inputs and routes to
`PdfConverter` (local) or `OfficeConverter` (pluggable repository). The
controller only knows the service, so swapping the Office implementation does
not change any widget.

**PDF reader.** `PdfReaderScreen` owns one `PdfSession` (`PdfService.open`), so
metadata and page reads reuse the parsed document instead of re-opening the
file. Pages render at 1600 px once, are cached in a small 5-page window and
prefetched one page ahead; rendering is serialized because the native engine
shares one worker. The PageView provides swiping while each page has its own
`InteractiveViewer` for pinch zoom. The session is disposed when the screen
closes, which releases the native document and worker.

**PDF editing.** The editor keeps page order/rotation in `PdfPageRef`, markup in
`PdfMark` (normalized display coordinates) and search replacements in
`PdfTextReplacement` (unrotated PDF points). No bytes change until Save.
`PdfGeometry` maps between rotated screen space and unrotated PDF space; a page
rotation remaps existing marks so they stay attached to the same content.
On Save, `PdfService.saveEdits` performs one rewrite: redact old text runs and
stamp replacements, add text/highlight/ink/image stamps, apply page order
(which also drops deleted pages), then set each page's absolute rotation. The
default output is a new `*_edited_*.pdf`; overwrite writes a temp file and only
replaces the original after the rewrite succeeds, restoring the backup if the
rename fails. Merge and Extract first write the current edits to a temp file, so
they include unsaved changes, then produce and register a new PDF.

**PDF failures.** `PdfService` maps engine exceptions to typed `PdfFailure`s:
password required, wrong password, corrupted/incomplete, unsupported feature,
I/O and unknown. The reader/editor show a password prompt, a retryable error or
a snackbar accordingly. Scanned pages are classified with the engine's page
classifier; text editing then redirects to PDF → DOCX instead of pretending the
raster has editable text.

### Office conversion flow

`OfficeConversionRepository` is the boundary. Two implementations ship:

| Implementation | When | Behaviour |
| --- | --- | --- |
| `MockOfficeConversionRepository` | `OFFICE_API_URL` not set | Simulates upload/convert/download progress with real delays and writes valid, clearly-labelled placeholder PDF/DOCX/XLSX files. |
| `RestOfficeConversionRepository` | `OFFICE_API_URL` set | Multipart POST with upload/download progress, 20 s connect + 3 min transfer timeouts, typed error mapping, `content-disposition` parsing. |

Flow for every Office mode:

1. Pick a file (system picker or local history).
2. `RepositoryOfficeConverter` validates the extension for the target, rejects
   empty files and anything over 25 MB (server must enforce this too).
3. Upload → convert → download, reporting `OfficeProgress` stages to the UI.
4. Bytes are written to the app exports folder, registered in Hive history, and
   the result card offers Share / View in Files (preview).

Configure the real backend (no code change needed):

```bash
flutter run \
  --dart-define=OFFICE_API_URL=https://convert.example.com \
  --dart-define=OFFICE_API_KEY=<token>
```

Contract, error codes, security and temp-file cleanup guidance:
[`docs/office-conversion-api.md`](docs/office-conversion-api.md).

To plug a different engine, implement `OfficeConversionRepository` and return it
from `AppServices.bootstrap()`; nothing above the service layer changes.

## Run

```bash
flutter pub get
flutter run
```

Requires Flutter 3.35+ (built with 3.47.7, Dart 3.13.5). Android/iOS only;
desktop/web are not targeted because `pdfx`/`image_picker` are mobile plugins.

## Android permissions & storage

- **Internet:** `INTERNET` is declared for the optional Office conversion
  backend only. Scans, image/PDF conversions and the file hub work offline; use
  HTTPS (release builds block cleartext traffic).
- **Camera:** `CAMERA` is declared for the in-app live scanner (camera plugin).
  The app requests it at runtime when the live scanner opens. The image stream
  is analysed on the device only; no frame leaves the phone. `uses-feature` for
  the camera is `required="false"` so the app still installs on devices without
  one, and the system-camera fallback (`image_picker`, which uses its own
  permission flow) remains available if the in-app camera is denied.
- **Storage:** files stay in `getApplicationDocumentsDirectory()` (app-private)
  and `getCacheDirectory()`. No `READ/WRITE_EXTERNAL_STORAGE` or
  `MANAGE_EXTERNAL_STORAGE` is needed on Android 10+ (scoped storage).
- **Importing:** `file_picker`/`image_picker` use the Storage Access Framework,
  which grants per-file access without broad storage permissions.
- **Opening files:** `open_filex` needs package visibility. The manifest declares
  a `<queries>` entry for `ACTION_VIEW` with `*/*`; without it, "Open with"
  silently fails on Android 11+.
- **PDF engine:** `pdf_manipulator` ships a prebuilt native engine through its
  build hook; no Android permission or manifest change is needed. The hook
  downloads the correct binary on the first build, and the engine adds to the
  APK size. All PDF parsing/rewriting runs off the Dart UI isolate.
- **Sharing:** `share_plus` uses a FileProvider configured by the plugin; no
  extra permission or manifest entry is required. `FileAccessService` validates
  each path (exists and non-empty), attaches the MIME type for the extension
  (`application/pdf`, `image/jpeg`, `image/png`, Office types, …) and passes
  app-private file paths to the provider. Receivers such as WhatsApp, Gmail,
  Drive or Bluetooth get a proper content URI, so no storage permission is
  needed. Paths are never `file://` URIs and are not exposed outside the
  provider. Missing/unreadable files are skipped with a snackbar instead of a
  broken share intent.
- iOS would need `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription`
  in `Info.plist` if you build for iOS.

## Edge cases worth testing on a physical device

1. **EXIF rotation:** photos taken in portrait on a phone whose sensor is
   landscape. The preview may show the raw orientation until exported; the
   export bakes the EXIF orientation. Rotate + export and compare.
2. **Rotation + crop combos:** crop, rotate twice, crop again, export. The crop
   must stay on the intended region (covered by unit tests for the rect math).
3. **Large images / OOM:** 48–108 MP photos. Editing must stay responsive; export
   should not crash (pipeline downscales, preview decodes at 1600 px).
4. **HEIC/HEIF imports:** `image` may fail to decode; the app should show the
   "unsupported image" error rather than a blank page.
5. **Long PDFs:** 100+ page PDF → images. Rendering is serial (pdfx limitation);
   watch memory and cancel behaviour.
6. **Rename collisions:** rename a file to an existing name; the app should
   refuse with a message instead of overwriting.
7. **Files deleted outside the app:** remove an export via a file manager, then
   open it from the hub. Preview shows a clear "file not found" state.
8. **Storage full:** export a large batch with little free space. Errors must
   surface as a snackbar, not a crash.
9. **Share sheets:** share a PDF and multiple JPGs to Gmail/Drive/WhatsApp and
   Bluetooth; check file names, MIME handling and that every file arrives. Share
   from the export summary, the converter result, a file row and the preview
   screen.
10. **Back navigation:** leave the editor with unsaved pages, rotate the device,
    background the app during export, then return.
11. **Permission denial:** deny camera in the system camera app; the batch should
    remain unchanged with an error message.
12. **Office backend offline:** stop the server or enable airplane mode during a
    DOCX→PDF conversion. The upload must fail with a retryable network error and
    leave no partial file in history.
13. **Oversized/corrupt Office files:** a 30 MB DOCX or a renamed `.jpg` must be
    rejected before upload with a clear message.
14. **Backend timeout:** make the converter sleep longer than the client timeout;
    the UI must return to an idle state with a retry option.
15. **DOCX/XLSX output:** after PDF→Word/Excel, tap the result in Files and use
    "Open with" to confirm the device's Office app can open it (demo backend
    produces valid placeholder packages).
16. **Live overlay alignment:** hold a page at an angle, then turn the phone
    through all four orientations. The outline must stay on the paper (this is
    the camera-frame → preview rotation and `BoxFit.cover` mapping). Also test
    on a 16:9 and a 20:9 screen, where the preview crop differs.
17. **Low contrast / one bright surface:** scan white paper on a white desk and
    a page in shadow. The overlay should turn amber (low confidence) rather than
    guess silently; manual shutter plus Adjust must recover the page.
18. **Auto-capture:** enable it, hold a page still (one capture), slide the next
    page in (it should re-arm), and wiggle the phone (no capture while moving).
    With auto off, the shutter must always work.
19. **Thermal / frame rate:** run the live scanner for 5+ minutes on a mid-range
    Android phone. The preview should stay smooth; frames are dropped, not
    queued, so latency must not grow. Watch battery/heat and raise the analysis
    size only if needed.
20. **Camera denied:** deny the camera permission when the live scanner opens,
    then use "Use system camera". The batch must still accept pages and the
    permission error must be readable, not a crash.
21. **Multi-file share:** export a batch as images and share all pages at once;
    repeat from the converter result. Every image must arrive and the receiving
    app must treat them as images (not generic files).
22. **Missing file share:** delete an export with a file manager, then tap Share
    on its hub row. Expect a clear "missing/empty" message, not a crash or an
    empty chooser.
23. **Hub filters:** with scans, PDFs and converted files present, switch chips
    and combine them with a search term. Counts and empty states must stay
    accurate; "Show all files" must reset both.
24. **Thumbnail quick actions:** in the batch strip, rotate, recrop and delete a
    page that is not selected. The large preview, page numbering and exported
    order must update correctly; deleting the last page must leave the editor
    cleanly.
25. **PDF reader:** open a 50+ page PDF, swipe quickly, jump with the slider and
    pinch-zoom. Adjacent pages should appear without blank flashes and memory
    should stay flat (the render cache is capped at five pages).
26. **PDF page edits:** reorder, rotate and delete pages, save as a new PDF,
    then reopen and confirm the order/rotation. Check that deleting the last
    remaining page is blocked.
27. **PDF markup:** add text, highlight, ink and an image/signature stamp to a
    rotated page. Save, reopen, and verify marks stay on the intended content.
    Check multiple marks, colours and undo-last-mark.
28. **PDF text replacement:** use a born-digital PDF, search a word, replace it
    and save. The old word must be gone and the replacement visible. On a
    scanned PDF, the editor must report no text layer and offer DOCX conversion.
29. **PDF merge/extract:** make unsaved edits, merge another PDF, and extract a
    selection. Both outputs must include the pending edits and appear in Files.
30. **PDF passwords/corruption:** open a password PDF (try wrong then correct
    password) and a truncated/corrupt PDF. Expect a password form or a clear
    retryable error, never a crash.
31. **PDF overwrite safety:** choose Overwrite original only after confirmation;
    confirm the file is replaced, the Files row updates, and a failed save leaves
    the original intact.

## Known limitations

- Without `OFFICE_API_URL`, Office modes use the demo backend: outputs are valid
  placeholder files, not the real document. The converter shows a notice.
- PDF → DOCX/XLSX fidelity depends on the backend; PDFs describe glyph
  positions, so editable output is approximate.
- PDF text replacement removes the original run with a true redaction and draws
  the replacement as a foreground stamp. It is visually clean but the new text
  is not guaranteed to be selectable/searchable, and the original font is not
  preserved; the editor uses a close default face and size. Use DOCX conversion
  when full text-layer fidelity matters.
- Scanned/image-only PDFs have no editable text layer. Text editing detects this
  and offers PDF → DOCX; there is no built-in OCR.
- Saving flattens annotations on the edited document into page content so the
  output matches the editor preview and renders consistently across PDF
  viewers. Existing comments, stamps and form appearances on those pages become
  static as a side effect.
- The PDF engine (`pdf_manipulator`) is a native dependency delivered by a build
  hook. First builds need network access to fetch the binary, and the APK grows
  accordingly. Very large or vector-heavy pages take longer to rasterize; the
  reader bounds page width and keeps only five images in memory.
- PDF page preview now swipes between pages and prefetches one neighbour, but it
  is not a continuous-scroll canvas; jumping far with the slider shows a spinner
  until that page renders.
- Edge detection is heuristic: it assumes a bright sheet on a contrasting
  background. One-bright-surface scenes and very low contrast fall back to the
  full frame and rely on the manual corner handles. There is no shadow removal
  or curvature correction yet. The live overlay makes uncertainty visible
  (amber) but cannot invent edges that are not there.
- Live detection runs on the CPU in a Dart isolate. On devices where the camera
  plugin cannot start an image stream (or while another app holds the camera),
  the scanner shows a warning and keeps manual capture working, but the overlay
  has nothing to draw. "High resolution" capture uses `ResolutionPreset.veryHigh`
  (1080p-class); raise it in `LiveScanController` if the target devices handle
  the extra capture size.
- The perspective warp runs in pure Dart (isolate). A native/OpenCV
  implementation can replace `PerspectiveWarper` without touching the UI.
- PDF page preview uses a single page at a time by design; continuous scrolling
  with pre-rendering would need a page cache.

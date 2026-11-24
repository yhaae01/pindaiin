# Pindaiin — Document Scanner & File Super App

A local-first Flutter MVP: scan multiple pages, adjust each one, export to PDF or
images, manage the results in a file hub, and convert between images and PDFs.
All file processing happens on the device.

## Features

**Scanner**
- Capture pages with the system camera (one page per shot) or import several
  photos at once.
- Automatic document edge detection: the paper sheet is found, the page is
  perspective-warped (deskewed) and everything outside it — desk, hands,
  surroundings — is cropped away.
- Adjust edges: a zoomed preview with four draggable corner handles, so a
  missed or low-contrast detection can be fixed before the warp is applied.
- Batch editor: reorder by dragging, rotate left/right, fine-crop with corner
  handles, apply Original / Grayscale / Document filters, and re-adjust the
  perspective from the untouched original at any time.
- Export the batch as one multi-page PDF (quality presets) or one JPG/PNG per
  page. Exported files are registered in the file hub immediately.

**File hub**
- History of every exported/converted file with search, rename, preview, share,
  "open with", and delete.
- In-app preview: zoomable images and page-by-page PDF rendering.
- Metadata persisted in Hive; bytes live in app-private storage.

**Converter**
- Images (JPG/PNG/WebP) → PDF: fully offline.
- PDF → JPG images: fully offline.
- Office: DOCX/XLSX/DOC/XLS → PDF and PDF → DOCX/XLSX through an
  `OfficeConversionRepository`. Ships with a simulated demo backend and a REST
  client ready for a self-hosted renderer. Upload/download progress, validation
  (extension + 25 MB limit), timeouts and user-safe errors are handled.

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
│   │   ├── perspective_transform.dart  # 3x3 homography (unit square → quad)
│   │   ├── perspective_warper.dart     # PerspectiveWarper interface + warp
│   │   └── document_processor.dart     # facade: detect + warp by file path
│   ├── models/
│   │   ├── scanned_file.dart     # metadata model + JSON + FileKind/FileOrigin
│   │   ├── scan_page.dart        # page edits (rotation, crop, filter, source)
│   │   └── conversion.dart       # quality presets, modes, result types
│   ├── services/
│   │   ├── app_services.dart     # composition root (singletons + file registry)
│   │   ├── app_directories.dart  # app-private scans/exports/session folders
│   │   ├── file_storage_service.dart  # bytes, unique names, rename, delete
│   │   ├── file_repository.dart  # Hive box of JSON records (ChangeNotifier)
│   │   ├── file_access_service.dart   # camera, gallery, SAF picker, share, open
│   │   ├── image_processor.dart  # isolate export pipeline
│   │   ├── pdf_converter.dart    # images→PDF and PDF→images (pdf/pdfx)
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
│       ├── document_quad_overlay.dart  # draggable 4-corner page handles
│       ├── crop_overlay.dart     # interactive crop handles
│       └── status_views.dart     # empty/error/busy states, dialogs
└── features/
    ├── home/home_shell.dart
    ├── scanner/                  # controller, capture screen, edge editor, batch editor, crop, sheets
    ├── files/                    # controller, list, preview
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
| `image_picker` | Camera capture and multi-photo gallery import. |
| `file_picker` | System document picker for the converter (SAF on Android). |
| `image` | Decode/rotate/crop/filter/encode off the UI thread. |
| `pdf` | Writes merged multi-page PDFs with JPEG-compressed pages. |
| `pdfx` | Renders PDF pages for preview and PDF → images (platform PDFium). |
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

**Document capture and deskew.** Capturing a page goes through four stages:

1. **Detect** (`EdgeDocumentDetector`) — the photo is downscaled to 480 px, a
   luminance threshold (Otsu) separates the bright sheet from the background,
   the largest connected region is flood-filled, and the largest quadrilateral
   inscribed in its convex hull becomes the page outline. The result carries a
   confidence score instead of a hard yes/no.
2. **Confirm/adjust** (`DocumentEdgesScreen`) — a zoomed preview draws the four
   corners; drag a handle (pinch, +/− or Fit to zoom) when detection is
   uncertain, and pick the document filter with a live preview.
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
left untouched); camera captures always open the edge editor. The detector and
warper only meet at `DocumentProcessor`, constructed in
`AppServices.bootstrap()` — swapping either interface changes no widget or
controller.

**Export pipeline** (`ImageProcessor`, in an isolate):
`bake EXIF orientation → downscale to ≤3000 px → rotate → crop → filter → encode`.
JPEG quality comes from the preset (45/70/90). PNG export skips quality but
still bakes all edits. A PDF is built from the rendered JPEG pages, so the PDF
matches the preview exactly.

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
- **Camera:** no `CAMERA` permission is declared. `image_picker` launches the
  system camera app through an intent and receives the resulting photo, so
  declaring `CAMERA` would force a runtime permission prompt (and break the
  intent on some devices). The camera app handles its own permission.
- **Storage:** files stay in `getApplicationDocumentsDirectory()` (app-private)
  and `getCacheDirectory()`. No `READ/WRITE_EXTERNAL_STORAGE` or
  `MANAGE_EXTERNAL_STORAGE` is needed on Android 10+ (scoped storage).
- **Importing:** `file_picker`/`image_picker` use the Storage Access Framework,
  which grants per-file access without broad storage permissions.
- **Opening files:** `open_filex` needs package visibility. The manifest declares
  a `<queries>` entry for `ACTION_VIEW` with `*/*`; without it, "Open with"
  silently fails on Android 11+.
- **Sharing:** `share_plus` uses a FileProvider configured by the plugin; no
  extra permission or manifest entry is required.
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
9. **Share sheets:** share a PDF and multiple JPGs to Gmail/Drive/WhatsApp; check
   file names and that every file arrives.
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

## Known limitations

- Without `OFFICE_API_URL`, Office modes use the demo backend: outputs are valid
  placeholder files, not the real document. The converter shows a notice.
- PDF → DOCX/XLSX fidelity depends on the backend; PDFs describe glyph
  positions, so editable output is approximate.
- PDF → images always outputs JPG (quality preset controls resolution/quality).
- No OCR, no cloud sync, no multi-select in the file hub yet.
- Edge detection is heuristic: it assumes a bright sheet on a contrasting
  background. One-bright-surface scenes and very low contrast fall back to the
  full frame and rely on the manual corner handles. There is no shadow removal
  or curvature correction yet.
- The perspective warp runs in pure Dart (isolate). A native/OpenCV
  implementation can replace `PerspectiveWarper` without touching the UI.
- PDF page preview uses a single page at a time by design; continuous scrolling
  with pre-rendering would need a page cache.

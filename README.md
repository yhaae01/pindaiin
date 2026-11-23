# Pindaiin — Document Scanner & File Super App

A local-first Flutter MVP: scan multiple pages, adjust each one, export to PDF or
images, manage the results in a file hub, and convert between images and PDFs.
All file processing happens on the device.

## Features

**Scanner**
- Capture pages with the system camera (one page per shot) or import several
  photos at once.
- Batch editor: reorder by dragging, rotate left/right, crop with corner
  handles, apply Original / Grayscale / Document filters.
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
- Office (DOCX/XLSX) → PDF: routed through `OfficeConverter`. A stub with a
  clear UI notice is shipped; the interface is ready for a backend.

## Project structure

```
lib/
├── main.dart                     # Hive init + bootstrap + runApp
├── app.dart                      # providers, MaterialApp, theme
├── core/
│   ├── models/
│   │   ├── scanned_file.dart     # metadata model + JSON + FileKind/FileOrigin
│   │   ├── scan_page.dart        # page edits (rotation, crop, filter)
│   │   └── conversion.dart       # quality presets, modes, result types
│   ├── services/
│   │   ├── app_services.dart     # composition root (singletons + file registry)
│   │   ├── app_directories.dart  # app-private scans/exports/session folders
│   │   ├── file_storage_service.dart  # bytes, unique names, rename, delete
│   │   ├── file_repository.dart  # Hive box of JSON records (ChangeNotifier)
│   │   ├── file_access_service.dart   # camera, gallery, SAF picker, share, open
│   │   ├── image_processor.dart  # isolate export pipeline
│   │   ├── pdf_converter.dart    # images→PDF and PDF→images (pdf/pdfx)
│   │   ├── office_converter.dart # interface + unavailable stub
│   │   └── document_converter_service.dart  # validates and routes conversions
│   ├── theme/app_theme.dart
│   ├── utils/formatters.dart
│   └── widgets/
│       ├── scan_page_image.dart  # rotation/crop/filter preview painter
│       ├── crop_overlay.dart     # interactive crop handles
│       └── status_views.dart     # empty/error/busy states, dialogs
└── features/
    ├── home/home_shell.dart
    ├── scanner/                  # controller, capture screen, editor, crop, sheets
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

## How key flows work

**Non-destructive editing.** A `ScanPage` stores `quarterTurns`, a crop `Rect`
normalized to the *rotated* page, and a filter. Rotating a page also rotates its
crop, so the visible region stays put. Nothing is re-encoded while editing.

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
`PdfConverter` (local) or `OfficeConverter` (pluggable). The controller only
knows the service, so swapping the Office stub for a network implementation does
not change any widget.

### Wiring an Office backend later

Implement `OfficeConverter`:

```dart
class HttpOfficeConverter implements OfficeConverter {
  @override
  bool get isAvailable => true;

  @override
  String get availabilityNote => '';

  @override
  Future<ConversionArtifact> convertToPdf({
    required String inputPath,
    required String outputPath,
    void Function(double progress)? onProgress,
  }) async {
    // 1. POST the file (signed URL or multipart).
    // 2. Poll / await webhook.
    // 3. Download the PDF to outputPath.
    // 4. Report progress; throw ConversionException on failure.
  }
}
```

Then construct it in `AppServices.bootstrap()` instead of
`UnavailableOfficeConverter`. The converter tab and its disabled state update
automatically.

## Run

```bash
flutter pub get
flutter run
```

Requires Flutter 3.35+ (built with 3.47.7, Dart 3.13.5). Android/iOS only;
desktop/web are not targeted because `pdfx`/`image_picker` are mobile plugins.

## Android permissions & storage

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

## Known limitations

- Office conversions are not implemented locally; the UI disables them until an
  `OfficeConverter` is provided.
- PDF → images always outputs JPG (quality preset controls resolution/quality).
- No OCR, no cloud sync, no multi-select in the file hub yet.
- PDF page preview uses a single page at a time by design; continuous scrolling
  with pre-rendering would need a page cache.

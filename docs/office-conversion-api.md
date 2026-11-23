# Office Conversion API contract

Client-side code: `RestOfficeConversionRepository`
(`lib/core/services/office/rest_office_conversion_repository.dart`).
Server-side reference: any service able to run LibreOffice headless (or a
commercial conversion engine) in a sandbox.

Scope: `DOCX`/`XLSX`/`DOC`/`XLS` → `PDF`, and `PDF` → `DOCX`/`XLSX`.

> PDF → DOCX/XLSX is inherently approximate: PDF stores positioned glyphs, not
> semantic paragraphs or cells. Expect text frames/tables, not a perfect original
> document. Advertising "editable export" rather than "pixel-perfect" is honest.

## Endpoint

```
POST /v1/office/convert
```

### Request

`multipart/form-data`, exactly one file per request.

| Part | Type | Required | Description |
| --- | --- | --- | --- |
| `file` | binary | yes | Source document. Max **25 MB** (server must enforce too). |
| `target` | text | yes | `pdf`, `docx`, or `xlsx`. |
| `source` | text | no | Declared extension (`docx`, `xlsx`, `pdf`, …). Server must still sniff the bytes. |
| `options` | JSON string | no | Engine hints, e.g. `{"sheet":"all","ocr":false,"pdfa":false}`. |

Headers:

```
Authorization: Bearer <short-lived token>
Accept: application/pdf | application/vnd.openxmlformats-officedocument.wordprocessingml.document | ...spreadsheetml.sheet
Content-Type: multipart/form-data; boundary=...
X-Request-Id: <uuid>          # optional, echoed for tracing
```

Example:

```bash
curl -X POST https://convert.example.com/v1/office/convert \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/pdf" \
  -F "target=pdf" \
  -F "file=@invoice.docx"
```

### Success response

```
HTTP/1.1 200 OK
Content-Type: application/pdf
Content-Disposition: attachment; filename="invoice.pdf"
Content-Length: 482913
X-Conversion-Id: 0f5c2f5e-...
X-Engine-Version: libreoffice-24.2
Cache-Control: no-store
```

Body: the raw converted bytes. Do not wrap them in JSON/Base64; the client
streams them to disk and Base64 adds ~33 % overhead.

Optional asynchronous variant (recommended once conversions exceed ~20 s):

```
HTTP/1.1 202 Accepted
Content-Type: application/json

{"job_id": "…", "status": "queued", "poll_url": "/v1/jobs/…", "expires_at": "…"}
```

The client would then poll `poll_url` until `status: "done"`, fetch
`download_url` (signed, single use, 5 min TTL), or use a webhook. The bundled
Flutter client implements the synchronous binary contract.

### Error response

```json
{
  "error": {
    "code": "unsupported_format",
    "message": "The uploaded file is not a valid DOCX document."
  }
}
```

| Status | `code` | Client mapping (Flutter `OfficeErrorCode`) |
| --- | --- | --- |
| 400 | `invalid_request` | `server` (not retryable) |
| 401/403 | `unauthorized` | `unavailable` |
| 413 | `file_too_large` | `fileTooLarge` |
| 415 | `unsupported_format` | `unsupportedFormat` |
| 422 | `conversion_failed` (corrupt/encrypted doc) | `unsupportedFormat` |
| 429 | `rate_limited` | `server`, retryable |
| 500/502/503 | `engine_error` / `unavailable` | `server`, retryable |
| timeout | – | `timeout`, retryable |

Rules:
- Always return JSON errors; never dump stack traces, temp paths, or engine logs.
- Include `Retry-After` on 429/503.
- Never echo the uploaded file contents or user filename in logs.

## Client behaviour

- **Validation before upload:** extension is checked against the target
  (`OfficeTarget.acceptsPath`) and size against `maxUploadBytes` (25 MB); empty
  files are rejected early.
- **Progress:** upload maps to 0–75 %, download can reach 100 %. The UI shows
  stage labels (`Uploading…`, `Converting on server…`, `Downloading result…`,
  `Saving…`) from `OfficeProgress`.
- **Timeouts:** connect 20 s, send/receive 3 min. `DioException` types are mapped
  to user-safe messages; 5xx/429 are marked retryable.
- **Output:** bytes are written into the app's exports directory, then registered
  in the local file history with `FileOrigin.conversion`; DOCX/XLSX appear as
  Word/Spreadsheet entries.
- **No background upload:** conversion requires the app to stay in the
  foreground in this MVP.
- **TLS:** the client refuses cleartext because Android's default network
  security config does not allow it for release builds.

## Server-side security & temporary file handling

1. **Transport & auth**
   - TLS 1.2+ only; HSTS; no API keys in URLs.
   - Bearer tokens scoped to `convert:write`, short TTL, per-user/IP rate limits.
2. **Input validation**
   - Sniff magic bytes (`PK\x03\x04` for OOXML, `%PDF-` for PDF); never trust
     `Content-Type` or the extension.
   - Reject encrypted/password-protected documents and files with macros.
   - Cap decompressed OOXML size, entry count and compression ratio (zip bombs),
     and cap PDF page count / object nesting.
   - Reject embedded OLE objects, external relationships and remote fonts.
3. **Sandboxed conversion**
   - One process per job, unprivileged user, read-only root FS, no network
     (`--network none`), seccomp/AppArmor, CPU/memory/wall-clock limits
     (recommend 120 s, 1 GB), concurrency limits and a queue.
   - Disable LibreOffice macros and the "update links on load" behaviour; use a
     dedicated profile (`-env:UserInstallation=file:///tmp/lo-profile-<job>`).
   - Never interpolate user filenames into a shell string; always exec an
     argument array and use `--outdir`.
4. **Temporary files**
   - Per-job directory: `/var/tmp/convert/<uuid>/`, mode `0700`, containing the
     upload, output and LibreOffice profile.
   - Delete in a `finally` block on success, failure, timeout and client
     disconnect; kill the whole process group first.
   - A startup/cron sweeper removes job dirs older than 1 hour (covers crashes).
   - Never reuse directories between jobs; never write inside the app source
     tree.
5. **Output handling**
   - Return only the converted bytes; scan with AV if the product requires it.
   - Strip or preserve metadata deliberately (PDF producer, author, GPS).
   - Set `Cache-Control: no-store`; do not persist results after the request
     unless an async flow with signed, single-use download URLs is used.
6. **Observability & privacy**
   - Log job id, target, size, duration and status only.
   - Document retention: zero-copy by default; PII in documents is not logged.
   - Per-tenant quotas and abuse monitoring.

## Flutter configuration

```bash
# Demo mode (default): valid placeholder outputs, no network calls.
flutter run

# Real backend
flutter run \
  --dart-define=OFFICE_API_URL=https://convert.example.com \
  --dart-define=OFFICE_API_KEY=<token>
```

Only the composition root (`AppServices.bootstrap`) changes behaviour; the
converter UI, controller and history registration are backend-agnostic.

# PDFMathReader for iOS: replication plan

Source app: `/Users/rongxin/Developer/oss/PDFMathReader` (v0.1.11, `2f47e8f`).
Toolchain on this Mac: Xcode 27.0, iOS SDK 27.0.

## 1. Decision: native SwiftUI + PDFKit, Ultra fast on device, math kernels remote

The desktop app is Vue + PDF.js (renderer), Express (local backend), Electron (shell),
and Python `uv` environments running PDFMathTranslate (Fast) and PDFMathTranslate-next /
BabelDOC (Precise). iOS cannot spawn Node, Python, `uv`, or child processes, so the
backend and kernels cannot be ported as-is.

Recommended shape:

| Desktop layer | iOS replacement |
| --- | --- |
| Electron windows, menus, IPC | SwiftUI scenes (multi-window on iPad), `DocumentGroup`/Files import, commands + keyboard shortcuts |
| PDF.js canvas + virtualized pages | PDFKit `PDFView` (tiling, zoom, thumbnails, page modes) |
| DOM paragraph overlays / reading text layer | `PDFPageOverlayViewProvider` per-page SwiftUI/UIKit overlays |
| Express backend (`server/`) | In-process Swift actors in a `ReaderCore` Swift package |
| Ultra fast: PDF Inspector / pdf.js text items -> `paragraphs()` | PDFKit glyph extraction -> Swift port of `server/documents/layout.mjs` |
| Fast / Precise Python kernels | Remote only: zotero-pdf2zh protocol (port `server/kernels/remote-kernel.mjs`), later a paired desktop "companion kernel" |
| macOS local translation helper (`local-translation.swift`) | Apple `Translation` framework directly (`TranslationSession`) |
| `safeStorage` / Keychain | Keychain (`kSecAttrAccessibleAfterFirstUnlock`) |
| Translation/layout caches in Application Support | Same layout under app container `Library/Caches` + `Application Support` |
| pdf-lib exports and annotations | PDFKit `PDFAnnotation` + `PDFDocument.write` |
| Finder/AirDrop actions | `ShareLink` / `UIActivityViewController`, Files export |

Rejected alternative: wrap the Vue UI in Capacitor/WKWebView. Its UI is a desktop
design system (MacVue / Fluent), the backend still needs a full rewrite because there is
no Node runtime, and PDF.js canvas rendering in WKWebView hits iPhone memory limits on
long papers. Reuse comes from *behavior parity via fixtures*, not shared code.

## 2. Parity strategy: golden fixtures generated from the desktop code

Port pure logic to Swift, and prove parity against the JS originals:

1. Add `tools/export-fixtures.mjs` (in this repo) that imports desktop modules by path
   (`server/documents/layout.mjs`, `shared/translation/*.mjs`,
   `src/features/translation/bionic-reading.mjs`, `shared/reader/link-detection.mjs`)
   and writes JSON input/output pairs for a fixed set of sample PDFs.
2. Swift tests load those fixtures and assert equal output (with float tolerance).
3. Re-run the export on each desktop release to catch drift.

Text extraction itself will differ (PDFKit vs PDF Inspector / pdf.js), so add a second
fixture tier: desktop `extractPdfJsPositions` items for each sample page, compared
against the PDFKit extractor with tolerance on boxes and exact text after normalization.

## 3. Modules

```
PDFMathReader-iOS/
  App/                      SwiftUI app target (iPhone + iPad, iOS 18+)
  Packages/ReaderCore/      no UIKit; unit-testable on macOS
    Layout/                 TextItem, PDFKitExtractor, Paragraphs (layout.mjs port),
                            OCR item normalization, paragraph compaction, TOC generator
    Translation/            Provider protocol, OpenAI-compatible, SiliconFlow free proxy,
                            custom services (service-schema.mjs), Apple Translation,
                            glossary, rich-text placeholders, spacing, language detection,
                            request coalescing + persistent cache (translation-cache.mjs keying)
    Kernels/                RemoteKernelClient (zotero-pdf2zh), page splitting, result merge
    Reading/                bionic reading, TF-IDF emphasis, topic sentences, link detection
    Library/                recents, per-document reading state, quick links, annotations store
  Fixtures/                 generated JSON + sample PDFs
  tools/export-fixtures.mjs
```

Project generation: XcodeGen (`project.yml`) so the `.xcodeproj` is not hand-edited.

## 4. Phases and exit criteria

**P0. Skeleton (1-2 days).** XcodeGen project, `ReaderCore` package, CI script
(`xcodebuild test` on an iOS simulator + `swift test` for the package), fixture exporter
with 3 sample PDFs (one two-column paper, one scanned PDF with hidden OCR text, one with
heavy math). *Exit:* app opens a PDF from Files and shows it in `PDFView`; fixture export runs.

**P1. Reader parity (1 week).** Library/start screen with recents, PDFKit reader with
thumbnails sidebar, zoom, vertical/horizontal scroll, 1/2/4-page layouts, outline/TOC,
search, restore reading position and display settings per document, iPad multi-window.
*Exit:* the behaviors in the README's "Flexible navigation" and "Multiple documents"
bullets work on iPhone and iPad simulators.

**P2. Ultra fast translation on device (1-2 weeks).** PDFKit text extractor ->
`Paragraphs` port -> translation queue (nearby pages first, cancel on
document/language/engine change, port of `src/features/translation/translation-queue.mjs`)
-> per-page overlays, tap a paragraph to toggle original/translation. Providers:
OpenAI-compatible key, SiliconFlow free proxy, Apple on-device Translation.
Persistent cache with the desktop key scheme. *Exit:* layout fixtures pass; a two-column
paper translates as you scroll; cache hits after relaunch; no request when cancelled.

**P3. Annotations and file actions (1 week).** Highlights and comments stored with the
same `PDFMathReader:`-prefixed managed annotations so files round-trip with desktop;
reading links; export the original or translated PDF (translated pages where available,
original pages elsewhere) through the share sheet and Files. *Exit:* a PDF annotated on iOS
opens on desktop with the same highlights, and the reverse also works.

**P4. Remote math kernels (1 week).** Swift port of the zotero-pdf2zh client: health
check, one-page uploads, polling, stage-based progress, page substitution in the reader.
Settings for server URL; local network permission string. *Exit:* Fast/Precise page
replaces the original page when a server is reachable, and the reader falls back to Ultra
fast when it is not.

**P5. Reading aids and settings (1 week).** Bionic reading (fixed-length and word-root),
TF-IDF emphasis, topic sentences, glossary editor, interface localization (port
`src/i18n/locales/*.mjs` to a String Catalog with a conversion script), side-by-side
compare view on iPad. *Exit:* bionic/emphasis fixtures pass; all 16+ locales build.

**P6. Optional / later.**
- Desktop companion kernel: add an opt-in LAN listener with a pairing token to the
  desktop backend so iOS can call `/api/math-page` on the user's Mac. This needs a
  desktop change; the current backend binds to `127.0.0.1` with per-window auth.
- Formula OCR: convert `breezedeus/pix2text-mfr-1.5` ONNX encoder/decoder to Core ML,
  downloaded on demand (about 120 MB) rather than bundled.
- ChatGPT Subscription sign-in through `ASWebAuthenticationSession`. Check the token
  sharing terms for mobile clients first.
- Long "translate all pages" jobs using `BGContinuedProcessingTask`.
- EPUB input.

Out of scope on iOS: local Python kernels and `uv`, developer window, performance
monitors, update checker (App Store/TestFlight handles it), Windows/Linux specifics.

## 5. Risks

- **Extraction fidelity.** PDFKit glyph boxes differ from PDF Inspector. Mitigation: the
  tier-2 fixtures; if they diverge badly, compile `@firecrawl/pdf-inspector`'s Rust core as
  an XCFramework.
- **Memory on iPhone.** Bound overlay/translation caches the same way
  `layout-extraction.mjs` does (page and byte limits), and render overlays only for visible pages.
- **Network policy and App Review.** The free proxy and user-supplied servers need clear
  disclosure that document text leaves the device; ATS exceptions only for user-entered
  LAN kernel URLs (`NSAllowsLocalNetworking`).
- **Licensing.** Desktop is AGPL-3.0 (`LICENSE`); App Store distribution of AGPL code is
  contentious. Decide the distribution channel (TestFlight/ad hoc vs App Store) and get
  maintainer agreement before publishing.

## 6. First concrete steps

1. `brew install xcodegen`; create `project.yml`, `App/`, `Packages/ReaderCore`.
2. Write `tools/export-fixtures.mjs` for `paragraphs()` and the glossary/placeholder modules.
3. Port `layout.mjs` -> `Paragraphs.swift` and make the fixture tests pass.
4. Build the PDFKit extractor and compare it against `extractPdfJsPositions` fixtures.
5. Wire one provider (OpenAI-compatible) end to end for a single page overlay.

## 7. Status (2026-10-16)

Implemented and building for the iOS Simulator SDK (`xcodebuild ... build`, zero warnings);
ReaderCore has 58 Swift Testing tests, all green, most driven by fixtures exported from the desktop JS.

- **P0/P1** done: library and recents, PDFKit reader, thumbnails, outline (with generated-TOC
  fallback), search, zoom, 1/2/4-page layouts, scroll direction, per-document state, multi-window.
- **P2** done: PDFKit extraction -> `LayoutEngine.paragraphs` (strict JS parity) ->
  `PageTranslationPipeline` -> overlays with tap-to-toggle and auto-fit. Providers: SiliconFlow
  free proxy, OpenAI-compatible (Keychain key), Apple Translation (iOS 26+). Desktop cache keys.
- **P3** done: desktop-compatible `PDFMathReader:` highlights/comments (round-trip fixtures,
  compressed object streams), quick links, export original/translated PDF via share sheet and Files.
- **P4** done in code: remote zotero-pdf2zh client, health check, page substitution, fallback.
- **P5** done: bionic (fixed/root), TF-IDF emphasis, topic sentences, link detection, glossary
  editor, iPad compare view, 16-locale String Catalog generated from desktop locales.
- **P6** partial: "Translate all pages" via `BGContinuedProcessingTask` (iOS 26) with
  `beginBackgroundTask` fallback; EPUB design note in `docs/EPUB.md`.

Not yet done: desktop companion kernel (needs a desktop change), formula OCR via Core ML,
ChatGPT subscription sign-in, EPUB implementation.

Not yet verified: no simulator runtime or device was available, so nothing has been run
interactively; no live network translation or remote-kernel call has been made.

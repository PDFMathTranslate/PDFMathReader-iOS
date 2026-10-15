# EPUB input feasibility

The desktop app supports `.epub` files, but it does not render EPUB directly in
the reader. It parses the EPUB ZIP container, reads the OPF manifest and linear
spine (plus navigation/NCX metadata), and renders each linear chapter in an
isolated Electron `BrowserWindow`. Electron prints those chapter pages to PDF;
the resulting PDFs are combined, given outlines and metadata, and cached by an
EPUB hash. The original EPUB remains unchanged, and annotations are written to
the converted PDF cache rather than back into the EPUB.

## iOS options

1. **Render chapters with `WKWebView`.** Add a ZIP/EPUB parser, serve the
   chapter and asset files from a restricted local URL scheme, and display the
   spine as paginated web content. This is the shortest route to reading EPUB,
   but it requires a separate translation/annotation coordinate system and does
   not preserve the PDFKit-based reader behavior.
2. **Convert EPUB to PDF.** Reuse the EPUB package/spine model, render each
   chapter with an HTML/CSS engine, and combine the pages into a PDF before
   opening the existing PDFKit reader. iOS does not provide Electron's
   `webContents.printToPDF`, so a native or maintained third-party renderer is
   still required. This option gives the closest parity for translation,
   thumbnails, search, outlines, export, and annotations, at the cost of more
   implementation and conversion time.

The recommended first phase is a read-only `WKWebView` prototype if EPUB
reading is needed before a renderer is selected. For PDFKit feature parity,
conversion is the better long-term design. In either case, enforce bounded ZIP
expansion, reject encrypted/DRM packages, keep extracted assets in an isolated
cache, and never modify the source EPUB. EPUB input is intentionally not
implemented in this iOS slice.

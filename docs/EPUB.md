# EPUB support

Import a `.epub` from Files using **Import PDF or EPUB**, or send one to
PDFMathReader using Open In. EPUBs are converted on device into paginated PDFs
before opening in the existing reader, following the desktop app's conversion
approach. Conversion does not require a translation server.

The generated PDF supports the reader's translation, search, thumbnails,
annotations, reading position, tabs, and PDF export. Recents reopen the local
PDF even if the incoming EPUB is later removed. The original EPUB is never
modified; annotations and exported changes belong to the converted PDF.

## Conversion

- Read the ZIP container, OPF metadata, and linear spine in publication order.
- Render each chapter with WebKit and paginate it with UIKit's print renderer.
- Include local styles and images, document metadata, and chapter outlines.
- Apply the selected Appearance translation font (or serif preference) to book
  text when converting. Without a font override, retain the book's own fonts.
- Cache the PDF by EPUB content hash, converter version, and effective font.
  Reimporting with the same font reuses its PDF and annotations. A different font
  creates a separate PDF without overwriting the previously annotated copy.

Book scripts and remote resources are disabled. Package paths cannot escape
the isolated book resources. Archive size and page limits bound conversion;
encrypted/DRM packages, malformed archives, and unsupported ZIP formats produce
an import error rather than a partial book.

## Limits

To apply a new font to an already converted book, import the EPUB again.
Previously converted PDFs in Recents retain their existing typography.

Layout is fixed at conversion time, rather than reflowed when the reader font
or window size changes. EPUB navigation targets point to chapter starts;
within-chapter fragments are not mapped to PDF coordinates. WebKit's print
layout may differ from a dedicated EPUB reader, especially for fixed-layout,
interactive, or multimedia books. The app exports PDF, not edited EPUB.

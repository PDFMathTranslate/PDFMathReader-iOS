# Layout fixtures

Regenerate with `node tools/export-layout-fixtures.mjs` from the repository root.

The document fixtures use the desktop fallback path: `extractPdfJsPositions` returns
the positioned items and those raw items are passed directly to `paragraphs(items,
height)`. In production, the native inspector path normally supplies the items to
`layout-extraction.mjs`; pages containing an image are re-read with pdf.js and
`normalizeOcrItems` only when the recovered text is substantially longer. The
synthetic fixture records the normalization output separately so the Swift port is
tested without changing the raw document-parity inputs.

`PDFKitTextExtractor` is intentionally checked with looser metrics. PDFKit character
boxes have glyph-specific vertical jitter and its extracted text can differ at the
edges of a PDF text stream (for example, `sample.pdf` loses the final `s` in
`Birds`). The extractor snaps nearby glyph runs to a common line coordinate; exact
item-box equality is therefore not expected even when paragraph text is close.

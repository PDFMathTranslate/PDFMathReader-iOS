# Apple Pencil drawing

Open a PDF and tap **Drawing Tools** (the pencil icon) in the reader toolbar.
The native PencilKit palette provides pens, colors, stroke widths, an eraser,
and lasso selection. Tap the toolbar button again to return to reading.

Apple Pencil is the default input. Finger touches continue to navigate the PDF.
To draw without a Pencil, enable **Draw with Finger** in the reader's More menu.
Turn Drawing Tools off to navigate or select text when finger drawing is enabled.
The More menu also provides **Undo Drawing** and **Redo Drawing** for the active
page's current editing session.

Drawings save automatically under Application Support/PDFMathReader/drawings,
separately from highlights and translations. Local saves follow the source file's
URL, so highlighting and rewriting the PDF does not orphan its drawings. Renaming
or moving the source file outside the app changes that local association; export
and reopen the exported PDF to carry editable drawings to a new location.

Original, translated, and AirDrop exports include both a standard PDF stamp
appearance and the original PencilKit data. Other PDF viewers can display the
appearance; reopening the exported file in PDFMathReader restores editable
strokes. Exported appearances are rasterized at twice PDF point resolution;
editable strokes retain their pressure, masks, and tool data.

Validation includes iPad simulator palette interaction, saving/reopening/erasing,
corrupt sidecar protection, and PDF appearance/data round trips. Apple Pencil
hardware input, palm rejection, and accessory gestures require a physical-device
check.

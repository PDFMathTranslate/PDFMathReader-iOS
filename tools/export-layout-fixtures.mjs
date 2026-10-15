#!/usr/bin/env node

import { createRequire } from 'node:module';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const desktopRoot = resolve(
  process.env.PDFMATHREADER_DESKTOP_ROOT || '/Users/rongxin/Developer/oss/PDFMathReader',
);
const fixturePdfRoot = join(repoRoot, 'Fixtures', 'pdfs');
const layoutRoot = join(repoRoot, 'Packages', 'ReaderCore', 'Tests', 'ReaderCoreTests', 'Fixtures', 'layout');

const desktopRequire = createRequire(pathToFileURL(join(desktopRoot, 'package.json')));
const { extractPdfJsPositions, normalizeOcrItems } = await import(
  pathToFileURL(join(desktopRoot, 'server/documents/pdf-extractor.mjs')).href
);
const { paragraphs } = await import(pathToFileURL(join(desktopRoot, 'server/documents/layout.mjs')).href);

async function loadPdfJs() {
  if (!globalThis.DOMMatrix) {
    globalThis.DOMMatrix = (await import(
      pathToFileURL(desktopRequire.resolve('@thednp/dommatrix')).href
    )).default;
  }
  const pdfjsRoot = dirname(desktopRequire.resolve('pdfjs-dist/package.json'));
  const module = await import(pathToFileURL(join(pdfjsRoot, 'legacy/build/pdf.mjs')).href);
  module.GlobalWorkerOptions.workerSrc = pathToFileURL(
    join(pdfjsRoot, 'legacy/build/pdf.worker.mjs'),
  ).href;
  return { module, pdfjsRoot };
}

async function pageSizes(bytes) {
  const { module, pdfjsRoot } = await loadPdfJs();
  const task = module.getDocument({
    data: new Uint8Array(bytes),
    isEvalSupported: false,
    useSystemFonts: false,
    disableFontFace: true,
    standardFontDataUrl: join(pdfjsRoot, 'standard_fonts') + '/',
    cMapUrl: join(pdfjsRoot, 'cmaps') + '/',
    cMapPacked: true,
  });
  try {
    const document = await task.promise;
    const result = [];
    for (let page = 1; page <= document.numPages; page++) {
      const viewport = (await document.getPage(page)).getViewport({ scale: 1 });
      result.push({ page, width: viewport.width, height: viewport.height });
    }
    return result;
  } finally {
    await task.destroy();
  }
}

async function exportDocument(fileName) {
  const bytes = await readFile(join(fixturePdfRoot, fileName));
  const sizes = await pageSizes(bytes);
  const pages = [];
  for (const size of sizes) {
    // Keep this call on the desktop implementation: it is the exact production
    // input path used by the no-native-inspector fallback.
    const items = await extractPdfJsPositions(bytes, [size.page]);
    pages.push({
      page: size.page,
      width: size.width,
      height: size.height,
      items,
      paragraphs: paragraphs(items, size.height),
    });
  }
  const outputName = fileName.replace(/\.pdf$/i, '.json');
  await writeFile(join(layoutRoot, outputName), `${JSON.stringify({ pages }, null, 2)}\n`);
  await copyFile(join(fixturePdfRoot, fileName), join(layoutRoot, fileName));
  return { fileName, pages };
}

const syntheticPageHeight = 400;

function syntheticItem(text, x, top, options = {}) {
  const fontSize = options.fontSize ?? 12;
  const height = options.height ?? fontSize;
  const width = options.width ?? Math.max(8, text.length * fontSize * 0.55);
  return {
    page: 1,
    text,
    x,
    y: syntheticPageHeight - top - height,
    width,
    height,
    fontSize,
    isBold: options.isBold ?? false,
    rotation: options.rotation ?? 0,
    itemType: options.itemType ?? 'Text',
  };
}

const syntheticCases = [
  {
    name: 'two-columns',
    pageHeight: syntheticPageHeight,
    items: [
      syntheticItem('Left column one', 40, 40, { width: 180 }),
      syntheticItem('Right column one', 320, 40, { width: 180 }),
      syntheticItem('Left column two', 40, 54, { width: 180 }),
      syntheticItem('Right column two', 320, 54, { width: 180 }),
    ],
  },
  {
    name: 'centered-bold-heading',
    pageHeight: syntheticPageHeight,
    items: [
      syntheticItem('A centered heading', 180, 30, {
        width: 240,
        fontSize: 18,
        isBold: true,
      }),
      syntheticItem('continued heading', 215, 50, {
        width: 170,
        fontSize: 18,
        isBold: true,
      }),
    ],
  },
  {
    name: 'bullet-list',
    pageHeight: syntheticPageHeight,
    items: [
      syntheticItem('• first bullet', 60, 80, { width: 100 }),
      syntheticItem('• second bullet', 60, 94, { width: 110 }),
      syntheticItem('• third bullet', 60, 108, { width: 100 }),
    ],
  },
  {
    name: 'hyphenated-line-wrap',
    pageHeight: syntheticPageHeight,
    items: [
      syntheticItem('inter-', 60, 140, { width: 50 }),
      syntheticItem('national', 60, 154, { width: 65 }),
    ],
  },
  {
    name: 'indented-first-line',
    pageHeight: syntheticPageHeight,
    items: [
      syntheticItem('An indented opening line', 90, 190, { width: 170 }),
      syntheticItem('continues at the margin', 60, 204, { width: 160 }),
      syntheticItem('and keeps going.', 60, 218, { width: 100 }),
    ],
  },
  {
    name: 'terminal-punctuation-boundary',
    pageHeight: syntheticPageHeight,
    items: [
      syntheticItem('A long sentence continues', 60, 260, { width: 190 }),
      syntheticItem('and ends.', 60, 274, { width: 60 }),
      syntheticItem('A new sentence starts', 60, 288, { width: 160 }),
    ],
  },
];

const normalizationItems = [
  syntheticItem('Hello', 20, 0, { fontSize: 10, height: 10 }),
  syntheticItem('world', 55, 0.1, { fontSize: 10.2, height: 10.2 }),
  syntheticItem('far', 180, 0, { fontSize: 10, height: 10 }),
  syntheticItem('Next', 20, 22, { fontSize: 8, height: 8 }),
];

async function exportSynthetic() {
  const cases = syntheticCases.map((value) => ({
    ...value,
    paragraphs: paragraphs(value.items, value.pageHeight),
  }));
  const normalization = {
    name: 'ocr-baseline-merge-and-body-size-snap',
    items: normalizationItems,
    normalized: normalizeOcrItems(normalizationItems),
  };
  await writeFile(
    join(layoutRoot, 'synthetic.json'),
    `${JSON.stringify({ cases, normalization: [normalization] }, null, 2)}\n`,
  );
}

await mkdir(layoutRoot, { recursive: true });
const documents = await Promise.all(['sample.pdf', 'precise-compaction.pdf'].map(exportDocument));
await exportSynthetic();
for (const document of documents) {
  const itemCount = document.pages.reduce((sum, page) => sum + page.items.length, 0);
  const paragraphCount = document.pages.reduce((sum, page) => sum + page.paragraphs.length, 0);
  console.log(`${document.fileName}: ${document.pages.length} page(s), ${itemCount} item(s), ${paragraphCount} paragraph(s)`);
}
console.log('synthetic.json: 6 paragraph edge-case cases and 1 OCR normalization case');

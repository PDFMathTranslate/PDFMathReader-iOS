#!/usr/bin/env node

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const desktopRoot = resolve(
  process.env.PDFMATHREADER_DESKTOP_ROOT || '/Users/rongxin/Developer/oss/PDFMathReader',
);
const fixtureRoot = join(repoRoot, 'Packages', 'ReaderCore', 'Tests', 'ReaderCoreTests', 'Fixtures', 'annotations');
const sourcePDF = join(repoRoot, 'Fixtures', 'pdfs', 'sample.pdf');
const { embedAnnotations } = await import(
  pathToFileURL(join(desktopRoot, 'electron/main/services/annotations.mjs')).href,
);
const { importPDFAnnotations } = await import(
  pathToFileURL(join(desktopRoot, 'electron/main/services/annotation-import.mjs')).href,
);

const annotations = [
  {
    id: 'desktop-highlight-1',
    page: 1,
    kind: 'highlight',
    origin: 'source',
    text: 'A desktop-written highlight',
    comment: '',
    color: '#fff36a',
    rects: [
      { x: 72, y: 110, width: 180, height: 14 },
      { x: 72, y: 128, width: 130, height: 14 },
    ],
    createdAt: '2026-01-02T03:04:05.000Z',
    author: 'PDFMathReader',
  },
  {
    id: 'desktop-comment-1',
    page: 1,
    kind: 'comment',
    origin: 'source',
    text: '',
    comment: 'A desktop-written comment',
    color: '#ff8a65',
    rects: [{ x: 300, y: 210, width: 16, height: 16 }],
    sourceRect: { x: 300, y: 210, width: 16, height: 16 },
    createdAt: '2026-01-02T03:04:05.000Z',
    author: 'PDFMathReader',
  },
];

async function createFixture() {
  const source = await readFile(sourcePDF);
  const output = await embedAnnotations(source, annotations);
  await mkdir(fixtureRoot, { recursive: true });
  await writeFile(join(fixtureRoot, 'desktop-written.pdf'), output);
  await writeFile(
    join(fixtureRoot, 'desktop-written.json'),
    `${JSON.stringify({ annotations }, null, 2)}\n`,
  );
  const imported = await importPDFAnnotations(output);
  await writeFile(
    join(fixtureRoot, 'desktop-imported.json'),
    `${JSON.stringify(imported, null, 2)}\n`,
  );
  console.log(`desktop-written.pdf: ${imported.annotations.length} managed annotation(s)`);
}

async function verifySwift(file) {
  const bytes = await readFile(resolve(file));
  const imported = await importPDFAnnotations(bytes);
  if (!imported.annotations.length) throw new Error('Swift PDF contains no managed annotations');
  if (imported.annotations.some((annotation) => !annotation.id || annotation.nativeRef)) {
    throw new Error('Swift PDF contains an invalid managed annotation payload');
  }
  console.log(`verified Swift PDF: ${imported.annotations.map((annotation) => annotation.id).join(', ')}`);
}

if (process.argv[2] === '--verify-swift') {
  if (!process.argv[3]) throw new Error('Usage: export-annotation-fixtures.mjs --verify-swift PATH');
  await verifySwift(process.argv[3]);
} else {
  await createFixture();
}

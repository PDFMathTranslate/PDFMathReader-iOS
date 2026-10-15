#!/usr/bin/env node

import { mkdtemp, readFile, rm, writeFile, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const desktopRoot = resolve(process.env.PDFMATHREADER_DESKTOP_ROOT || '/Users/rongxin/Developer/oss/PDFMathReader');
const fixtureRoot = join(repoRoot, 'Packages/ReaderCore/Tests/ReaderCoreTests/Fixtures/reading');
const desktopURL = (path) => pathToFileURL(join(desktopRoot, path)).href;

const bionic = await import(desktopURL('src/features/translation/bionic-reading.mjs'));
const info = await import(desktopURL('src/features/translation/information-emphasis.mjs'));
const tfidf = await import(desktopURL('src/features/translation/tfidf-weighting.mjs'));
const topic = await import(desktopURL('src/features/translation/topic-sentences.mjs'));
const toc = await import(desktopURL('src/features/reader/toc-generator.mjs'));
const compact = await import(desktopURL('src/features/reader/paragraph-compaction.mjs'));
const termCorpus = await import(desktopURL('server/documents/term-corpus.mjs'));
const links = await import(desktopURL('shared/reader/link-detection.mjs'));
const fonts = await import(desktopURL('shared/reader/translation-font.mjs'));

const stable = (value) => {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  return value;
};

const runs = [
  { text: 'inter-', x: 40, y: 30, width: 40, height: 12 },
  { text: 'national results', x: 40, y: 46, width: 110, height: 12 },
  { text: 'are higher', x: 170, y: 46, width: 75, height: 12 },
];

const bionicInputs = [
  { text: 'Reading aids make complicated words easier.', options: { mode: 'fixed', fixedLength: 3 } },
  { text: "international studies don't support the null result", options: { mode: 'root', fixedLength: 3 } },
  { text: '中文阅读辅助工具与日本語テキスト', options: { mode: 'fixed', fixedLength: 3 } },
  { text: 'A🙂é 42 — naïve', options: { mode: 'root' } },
  { text: 'edge', options: { mode: 'off', fixedLength: 9 } },
];

const informationInputs = [
  'The first result was significant; however, the evidence does not support a higher effect size.',
  '研究结果显示显著差异，但是证据不支持更高效应量。',
  'supporting supports supported; compare compared with higher',
  'not-result, result2, result',
];

const topicTexts = [
  'Short paragraph.',
  `${'This is a long sentence with enough words to trigger the topic sentence detector. '.repeat(2)}A second sentence follows here.`,
  `${'这是一个很长的中文句子用于测试主题句检测。'.repeat(35)}第二个句子在这里。`,
  'Dr. Smith reported 3.14 results. A second sentence follows.',
];

const topicLead = 'This is a long sentence with enough words to trigger the topic sentence detector and keep the paragraph intentionally verbose '.repeat(5);
const topicRuns = [
  { text: `${topicLead}. `, x: 40, y: 40, width: 350, height: 12 },
  { text: 'A second sentence follows here.', x: 40, y: 56, width: 190, height: 12 },
];
const topicBoxes = [{ x: 35, y: 35, width: 380, height: 40, id: 7, eligible: true }];

const tocSyntheticItems = [
  { text: 'Contents', x: 60, y: 370, width: 90, size: 16, bold: true },
  { text: '1. Introduction', x: 60, y: 400, width: 120, size: 12, bold: false },
  { text: '........', x: 220, y: 400, width: 50, size: 12, bold: false },
  { text: '1', x: 320, y: 400, width: 8, size: 12, bold: false },
  { text: '2. Methods', x: 60, y: 420, width: 100, size: 12, bold: false },
  { text: '........', x: 220, y: 420, width: 50, size: 12, bold: false },
  { text: '4', x: 320, y: 420, width: 8, size: 12, bold: false },
  { text: '3. Results', x: 60, y: 440, width: 95, size: 12, bold: false },
  { text: '........', x: 220, y: 440, width: 50, size: 12, bold: false },
  { text: '8', x: 320, y: 440, width: 8, size: 12, bold: false },
];

function tocItemToLine(item, number = 1) {
  return { ...item, page: number, pageWidth: 400, pageHeight: 500, right: item.x + item.width, chars: item.text.length };
}

async function loadPDFPages(fileName) {
  const desktopRequire = createRequire(pathToFileURL(join(desktopRoot, 'package.json')));
  const { extractPdfJsPositions } = await import(desktopURL('server/documents/pdf-extractor.mjs'));
  const bytes = await readFile(join(repoRoot, 'Fixtures/pdfs', fileName));
  if (!globalThis.DOMMatrix) globalThis.DOMMatrix = (await import(pathToFileURL(desktopRequire.resolve('@thednp/dommatrix')).href)).default;
  const pdfjsRoot = dirname(desktopRequire.resolve('pdfjs-dist/package.json'));
  const pdfjs = await import(pathToFileURL(join(pdfjsRoot, 'legacy/build/pdf.mjs')).href);
  pdfjs.GlobalWorkerOptions.workerSrc = pathToFileURL(join(pdfjsRoot, 'legacy/build/pdf.worker.mjs')).href;
  const task = pdfjs.getDocument({ data: new Uint8Array(bytes), isEvalSupported: false, useSystemFonts: false, disableFontFace: true, standardFontDataUrl: join(pdfjsRoot, 'standard_fonts') + '/', cMapUrl: join(pdfjsRoot, 'cmaps') + '/', cMapPacked: true });
  const document = await task.promise;
  const pages = [];
  try {
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber++) {
      const page = await document.getPage(pageNumber);
      const viewport = page.getViewport({ scale: 1 });
      const items = await extractPdfJsPositions(bytes, [pageNumber]);
      const topItems = items.map((item) => ({ text: item.text, x: item.x, y: viewport.height - item.y - item.height, width: item.width, size: item.fontSize || item.height, bold: item.isBold }));
      pages.push({ number: pageNumber, width: viewport.width, height: viewport.height, lines: toc.buildLines(topItems, { number: pageNumber, width: viewport.width, height: viewport.height }) });
      page.cleanup();
    }
  } finally {
    await task.destroy();
  }
  return pages;
}

const compactItems = [
  { str: 'one', transform: [10, 0, 0, 10, 0, 20] },
  { str: 'two', transform: [10, 0, 0, 10, 0, 32] },
  { str: 'three', transform: [10, 0, 0, 10, 0, 44] },
];
const compactOccupied = Array(32).fill(false);
for (const index of [1, 2, 28, 29]) compactOccupied[index] = true;
const compactSource = Array(46).fill(false);
for (let index = 1; index < compactSource.length; index++) compactSource[index] = true;
const compactCuts = compact.compactBands(compactOccupied, 1, 100, 10);

async function exportTermCorpus() {
  const directory = await mkdtemp(join(tmpdir(), 'pdfmathreader-reading-'));
  try {
    let clock = 0;
    const corpus = termCorpus.createTermCorpus({
      directory,
      maxDocuments: 2,
      maxTerms: 3,
      random: () => 0,
      now: () => ++clock,
    });
    const idA = 'a'.repeat(32);
    const idB = 'b'.repeat(32);
    const idC = 'c'.repeat(32);
    const addA = await corpus.add(idA, ['rareword', 'common', 'common', '中文']);
    const addB = await corpus.add(idB, ['common', 'other', '词语']);
    const touchA = await corpus.touch(idA);
    const addC = await corpus.add(idC, ['other', 'new', 'rareword']);
    const frequencies = await corpus.frequencies(idA, ['common', 'other', 'rareword', '中文']);
    const touchEvicted = await corpus.touch(idB);
    await corpus.flush();
    return { addA, addB, touchA, addC, frequencies, touchEvicted, documents: 2 };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

const tocPages = [
  { number: 1, width: 400, height: 500, lines: toc.buildLines(tocSyntheticItems, { number: 1, width: 400, height: 500 }) },
  { number: 2, width: 400, height: 500, lines: [tocItemToLine({ text: 'Introduction', x: 60, y: 60, width: 100, size: 16, bold: true }, 2)] },
  { number: 3, width: 400, height: 500, lines: [tocItemToLine({ text: 'Methods', x: 60, y: 60, width: 70, size: 16, bold: true }, 3)] },
  { number: 4, width: 400, height: 500, lines: [tocItemToLine({ text: 'Results', x: 60, y: 60, width: 65, size: 16, bold: true }, 4)] },
];

const fixtures = {
  version: '0.1.11',
  bionic: bionicInputs.map((input) => ({ ...input, normalized: bionic.normalizeBionicReading(input.options), fixation: [...new Set(input.text.match(/\S+/gu) || [])].map((word) => ({ word, length: bionic.bionicFixationLength(word, input.options) })), ranges: bionic.bionicReadingRanges(input.text, input.options), segments: bionic.withBionicSegments([{ text: input.text, start: 0, end: input.text.length }], bionic.bionicReadingRanges(input.text, input.options)) })),
  bionicRuns: { input: runs, fixed: bionic.bionicRunRanges(runs, { mode: 'fixed', fixedLength: 3 }), root: bionic.bionicRunRanges(runs, { mode: 'root' }) },
  information: informationInputs.map((text) => ({ text, ranges: info.importantInformationRanges(text), segments: info.informationTextSegments(text, { topicEnd: Math.min(text.length, 12), emphasizeInformation: true }) })),
  informationRuns: info.informationRunRanges(runs),
  tfidf: [
    'Rareword appears twice; common appears once.',
    '中文词语 and Unicode café.',
    'hyphenated-word and naïve terms.',
  ].map((text) => ({ text, term: tfidf.tfidfTokens(text), set: tfidf.tfidfTermSet([text]), ranges: tfidf.tfidfRanges(text, { documents: 4, frequency: (term) => term === 'common' ? 3 : 0 }) })),
  tfidfSample: tfidf.samplePageNumbers(0, 12, () => 0.5),
  tfidfRuns: { text: tfidf.tfidfRunText(runs), ranges: tfidf.tfidfRunRanges(runs, { documents: 4, frequency: () => 0 }) },
  termCorpus: await exportTermCorpus(),
  topic: topicTexts.map((text) => ({ text, first: topic.firstSentenceLength(text), length: topic.topicSentenceLength(text) })),
  topicRuns,
  topicBoxes,
  topicParagraphs: topic.topicSentenceParagraphs(topicRuns, topicBoxes),
  links: [
    'Read https://example.org/paper, email author@example.edu.',
    'Wrapped https://doi.\norg/10.1000/test.',
    '(www.example.com/path?q=1), www.example.com/path?q=1',
    'mailto:person@example.org and second@example.org',
  ].map((text) => ({ text, links: links.detectLinks(text), emails: links.detectEmails(text) })),
  fonts: [
    { serif: false, font: '', language: '' },
    { serif: true, font: '', language: 'Japanese' },
    { serif: false, font: 'My Font', language: 'en' },
    { serif: true, font: 'bad;font', language: 'Traditional Chinese' },
  ].map((input) => ({ ...input, stripped: fonts.stripTranslationFont(input.font), valid: fonts.isValidTranslationFont(input.font), family: fonts.translationFontFamily(input) })),
  compaction: { cuts: compactCuts, trailing: compact.trailingCut(compactSource, compactOccupied, 1, 10), mapped: compactCuts.map((cut) => compact.mapCompactY(cut.end + 5, compactCuts)), rect: compact.mapCompactRect({ x: 1, y: 20, width: 10, height: 30 }, compactCuts), typical: compact.typicalLineHeight(compactItems) },
  toc: { pages: tocPages, syntheticItems: tocSyntheticItems, syntheticLines: tocPages[0].lines, generated: await toc.generateToc({ numPages: tocPages.length, getPageLines: async (number) => tocPages.find((page) => page.number === number)?.lines || [], onProgress: () => {} }) },
  pdfToc: {},
};

for (const fileName of ['sample.pdf', 'precise-compaction.pdf']) {
  const pages = await loadPDFPages(fileName);
  fixtures.pdfToc[fileName] = { pages: pages.map((page) => ({ number: page.number, width: page.width, height: page.height, lines: page.lines })), generated: await toc.generateToc({ numPages: pages.length, getPageLines: async (number) => pages[number - 1]?.lines || [], onProgress: () => {} }) };
}

await mkdir(fixtureRoot, { recursive: true });
const output = join(fixtureRoot, 'reading-fixtures.json');
await writeFile(output, `${JSON.stringify(stable(fixtures), null, 2)}\n`);
console.log(`wrote ${output}`);
console.log(`modules: bionic=${fixtures.bionic.length}, information=${fixtures.information.length}, tfidf=${fixtures.tfidf.length}, topic=${fixtures.topic.length}, links=${fixtures.links.length}, fonts=${fixtures.fonts.length}, pdfToc=${Object.keys(fixtures.pdfToc).length}`);

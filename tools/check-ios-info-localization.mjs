import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const toolsDirectory = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(toolsDirectory);
const catalogPath = join(repoRoot, 'App', 'Resources', 'InfoPlist.xcstrings');
const locales = ['en', 'ar', 'arz', 'bn', 'de', 'es', 'fr', 'hi', 'ja', 'ko', 'pcm', 'pt', 'ru', 'ur', 'zh-CN', 'zh-TW'];
const expectedKey = 'NSLocalNetworkUsageDescription';
const expectedEnglish = 'PDFMathReader discovers nearby computers and connects to their shared translation kernels on your local network.';

const catalog = JSON.parse(await readFile(catalogPath, 'utf8'));
if (catalog.version !== '1.0') throw new Error('InfoPlist.xcstrings: version must be 1.0');
if (catalog.sourceLanguage !== 'en') throw new Error('InfoPlist.xcstrings: sourceLanguage must be en');

const keys = Object.keys(catalog.strings ?? {});
if (JSON.stringify(keys) !== JSON.stringify([expectedKey])) {
  throw new Error(`InfoPlist.xcstrings: expected exactly ${expectedKey}`);
}

const localizations = catalog.strings[expectedKey]?.localizations ?? {};
if (JSON.stringify(Object.keys(localizations).sort()) !== JSON.stringify([...locales].sort())) {
  throw new Error(`${expectedKey}: expected exactly ${locales.length} locales`);
}

for (const locale of locales) {
  const stringUnit = localizations[locale]?.stringUnit;
  if (stringUnit?.state !== 'translated') throw new Error(`${expectedKey}.${locale}: expected translated state`);
  if (typeof stringUnit.value !== 'string' || stringUnit.value.trim() === '') {
    throw new Error(`${expectedKey}.${locale}: expected a non-empty string`);
  }
}

if (localizations.en.stringUnit.value !== expectedEnglish) {
  throw new Error(`${expectedKey}.en: English value does not match Info.plist`);
}

console.log(`InfoPlist.xcstrings complete: ${expectedKey} × ${locales.length} locales`);

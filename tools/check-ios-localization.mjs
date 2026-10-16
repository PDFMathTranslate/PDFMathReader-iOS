import { readFile, readdir } from 'node:fs/promises';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const toolsDirectory = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(toolsDirectory);
const sourceRoot = join(repoRoot, 'App', 'Sources');
const catalogPath = join(repoRoot, 'App', 'Resources', 'Localizable.xcstrings');

async function swiftFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...await swiftFiles(path));
    } else if (entry.isFile() && entry.name.endsWith('.swift')) {
      files.push(path);
    }
  }

  return files;
}

const catalog = JSON.parse(await readFile(catalogPath, 'utf8'));
const catalogKeys = new Set(Object.keys(catalog.strings ?? {}));
const files = await swiftFiles(sourceRoot);
const references = [];
const locales = ['en', 'ar', 'arz', 'bn', 'de', 'es', 'fr', 'hi', 'ja', 'ko', 'pcm', 'pt', 'ru', 'ur', 'zh-CN', 'zh-TW'];
const referencedKeys = new Set();
const referencePattern = /L10n\.string\(\s*"([^"]+)"/g;

for (const file of files) {
  const contents = await readFile(file, 'utf8');
  // Include keys stored in option arrays and selected by switch/ternary too.
  for (const match of contents.matchAll(/"([^"\n]+)"/g)) {
    if (catalogKeys.has(match[1])) referencedKeys.add(match[1]);
  }
  for (const match of contents.matchAll(referencePattern)) {
    references.push({
      key: match[1],
      file: relative(repoRoot, file),
    });
  }
}

const missing = [...new Set(references
  .map((reference) => reference.key)
  .filter((key) => !catalogKeys.has(key)))].sort();

const incomplete = [];
const placeholders = (value) => [...value.matchAll(/%(?:\d+\$)?@/g)].map(match => match[0]).sort().join(',');
for (const key of referencedKeys) {
  const translations = catalog.strings[key].localizations ?? {};
  const english = translations.en?.stringUnit?.value ?? '';
  for (const locale of locales) {
    const unit = translations[locale]?.stringUnit;
    if (!unit || unit.state !== 'translated' || !unit.value?.trim()) {
      incomplete.push(`${key}.${locale}: missing translation`);
    } else if (placeholders(unit.value) !== placeholders(english)) {
      incomplete.push(`${key}.${locale}: format placeholders differ from English`);
    }
  }
}
if (incomplete.length) {
  console.error(incomplete.join('\n'));
  process.exitCode = 1;
}

if (missing.length > 0) {
  console.error(`Missing localization keys (${missing.length}):`);
  for (const key of missing) console.error(`- ${key}`);
  process.exitCode = 1;
} else {
  console.log(JSON.stringify({
    files: files.length,
    references: references.length,
    uniqueKeys: new Set(references.map((reference) => reference.key)).size,
    missing: [],
    checkedKeysIncludingDynamicOptions: referencedKeys.size,
    incompleteTranslations: incomplete.length,
  }));
}

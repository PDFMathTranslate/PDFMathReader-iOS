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
const referencePattern = /L10n\.string\(\s*"([^"]+)"/g;

for (const file of files) {
  const contents = await readFile(file, 'utf8');
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
  }));
}

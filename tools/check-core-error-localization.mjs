import { readFile, readdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const catalog = JSON.parse(await readFile(join(root, 'App/Resources/Localizable.xcstrings'), 'utf8'));
const locales = Object.keys(catalog.strings['settings.title'].localizations).sort();
const placeholders = value => [...value.matchAll(/\{\d+\}/g)].map(match => match[0]).sort();
let count = 0;
for (const source of ['core-error-strings.json', 'companion-strings.json']) {
  const entries = JSON.parse(await readFile(join(root, 'tools', source), 'utf8'));
  for (const [key, messages] of Object.entries(entries)) {
    if (JSON.stringify(Object.keys(messages).sort()) !== JSON.stringify(locales)) {
      throw new Error(`${source}: ${key}: incomplete locale set`);
    }
    const catalogKey = source.startsWith('core-') ? `core.error.${key}` : key;
    for (const locale of locales) {
      const value = messages[locale];
      if (typeof value !== 'string' || !value.trim()) throw new Error(`${key}.${locale}: empty translation`);
      if (locale !== 'en' && value === messages.en && messages.en.split(/\s+/).length > 4) {
        throw new Error(`${key}.${locale}: untranslated English sentence`);
      }
      if (JSON.stringify(placeholders(value)) !== JSON.stringify(placeholders(messages.en))) {
        throw new Error(`${key}.${locale}: placeholders differ`);
      }
      const unit = catalog.strings[catalogKey]?.localizations?.[locale]?.stringUnit;
      if (unit?.state !== 'translated' || unit.value !== value) {
        throw new Error(`${key}.${locale}: catalog is stale or incomplete`);
      }
    }
    count++;
  }
}

async function scan(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await scan(path);
    else if (path.endsWith('.swift')) {
      const contents = await readFile(path, 'utf8');
      for (const match of contents.matchAll(/ReaderLocalization\.(?:resolve|string)\(\s*"([^"\n]+)"/g)) {
        if (!catalog.strings[`core.error.${match[1]}`]) {
          throw new Error(`${path}: missing error template ${match[1]}`);
        }
      }
    }
  }
}
await scan(join(root, 'Packages/ReaderCore/Sources'));
await scan(join(root, 'App/Sources'));
console.log(`Core error and companion strings complete: ${count} templates × ${locales.length} locales`);

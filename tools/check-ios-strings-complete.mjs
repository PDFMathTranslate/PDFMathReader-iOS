import { readFile } from 'node:fs/promises';

const source = JSON.parse(await readFile(new URL('./ios-strings.json', import.meta.url), 'utf8'));
const locales = ['en', 'ar', 'arz', 'bn', 'de', 'es', 'fr', 'hi', 'ja', 'ko', 'pcm', 'pt', 'ru', 'ur', 'zh-CN', 'zh-TW'];
const placeholders = (value) => {
  const counts = new Map();
  for (const name of value.matchAll(/\{[^}]+\}|%(?:\d+\$)?@/g)) counts.set(name[0], (counts.get(name[0]) || 0) + 1);
  return [...counts.entries()].sort();
};

for (const [key, messages] of Object.entries(source)) {
  if (JSON.stringify(Object.keys(messages).sort()) !== JSON.stringify([...locales].sort())) {
    throw new Error(`${key}: expected exactly ${locales.length} locales`);
  }
  for (const locale of locales) {
    if (typeof messages[locale] !== 'string') throw new Error(`${key}.${locale}: expected a string`);
    if (JSON.stringify(placeholders(messages[locale])) !== JSON.stringify(placeholders(messages.en))) {
      throw new Error(`${key}.${locale}: placeholder multiset differs from English`);
    }
  }
}

console.log(`ios-strings complete: ${Object.keys(source).length} keys × ${locales.length} locales; placeholders match`);

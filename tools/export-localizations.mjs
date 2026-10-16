#!/usr/bin/env node

import { readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const desktopRoot = resolve(
  process.env.PDFMATHREADER_DESKTOP_ROOT || '/Users/rongxin/Developer/oss/PDFMathReader',
);
const localeRoot = join(desktopRoot, 'src/i18n/locales');
const output = join(repoRoot, 'App/Resources/Localizable.xcstrings');
const iosExtrasPath = join(repoRoot, 'tools/ios-strings.json');

const localeFiles = (await readdir(localeRoot))
  .filter((file) => file.endsWith('.mjs'))
  .sort();
const localeEntries = await Promise.all(
  localeFiles.map(async (file) => {
    const locale = file.slice(0, -'.mjs'.length);
    const module = await import(pathToFileURL(join(localeRoot, file)).href);
    return [locale, module.default];
  }),
);
const locales = Object.fromEntries(localeEntries);

const values = new Map();
const setValue = (key, locale, value) => {
  if (typeof value !== 'string') return;
  if (!values.has(key)) values.set(key, {});
  values.get(key)[locale] = value;
};

function flatten(value, prefix = '', result = {}) {
  if (typeof value === 'string') {
    result[prefix] = value;
    return result;
  }
  if (!value || typeof value !== 'object') return result;
  for (const [key, child] of Object.entries(value)) {
    flatten(child, prefix ? `${prefix}.${key}` : key, result);
  }
  return result;
}

for (const [locale, messages] of Object.entries(locales)) {
  for (const [key, value] of Object.entries(flatten(messages))) setValue(key, locale, value);
}

// iOS-only labels and messages live outside the generated desktop locale files.
// Keeping them in a small source file makes the catalog reproducible.
const iosExtras = JSON.parse(await readFile(iosExtrasPath, 'utf8'));
for (const [key, messages] of Object.entries(iosExtras)) {
  if (!key.startsWith('ios.')) throw new Error(`iOS localization key must use ios.*: ${key}`);
  for (const [locale, value] of Object.entries(messages)) setValue(key, locale, value);
}

// Native computer-document controls have no desktop counterpart.
const companionExtras = JSON.parse(await readFile(join(repoRoot, 'tools/companion-strings.json'), 'utf8'));
for (const [key, messages] of Object.entries(companionExtras)) {
  for (const [locale, value] of Object.entries(messages)) setValue(key, locale, value);
}

// The desktop menu has a few strings that are shared with the native shell.
// Keep these under a separate namespace while retaining the source labels.
const menuExtra = await import(
  pathToFileURL(join(desktopRoot, 'shared/i18n/menu-extra.mjs')).href,
);
const menuTabs = await import(pathToFileURL(join(desktopRoot, 'shared/i18n/menu-tabs.mjs')).href);

for (const [locale, messages] of Object.entries(menuExtra.MENU_EXTRA_MESSAGES)) {
  for (const [label, value] of Object.entries(messages)) {
    setValue(`menu.extra.messages.${label}`, locale, value);
    setValue(`menu.extra.messages.${label}`, 'en', label);
  }
}

const dynamicMenuLabels = [
  ['goTo', menuExtra.MENU_EXTRA_GO_TO_LABELS, 'Go to {percent}%'],
  ['about', menuExtra.MENU_EXTRA_ABOUT_LABELS, 'About {name}'],
  ['quit', menuExtra.MENU_EXTRA_QUIT_LABELS, 'Quit {name}'],
];
for (const [kind, table, english] of dynamicMenuLabels) {
  setValue(`menu.extra.${kind}`, 'en', english);
  for (const [locale, formatter] of Object.entries(table)) {
    setValue(`menu.extra.${kind}`, locale, formatter(kind === 'goTo' ? '{percent}' : '{name}'));
  }
}

const pageEditKeys = ['Edit', 'Rotate Current Page', 'Align Page Widths', 'Align Page Heights', 'Page Changes Saved'];
for (const [locale, labels] of Object.entries(menuExtra.MENU_EXTRA_PAGE_EDIT_LABELS)) {
  labels.forEach((value, index) => setValue(`menu.extra.pageEdit.${pageEditKeys[index]}`, locale, value));
}
pageEditKeys.forEach((key) => setValue(`menu.extra.pageEdit.${key}`, 'en', key));

for (const [locale, labels] of Object.entries(menuExtra.MENU_EXTRA_PAGE_BOUNDARY_LABELS)) {
  setValue('menu.extra.pageBoundary.First Page', locale, labels[0]);
  setValue('menu.extra.pageBoundary.Last Page', locale, labels[1]);
}
setValue('menu.extra.pageBoundary.First Page', 'en', 'First Page');
setValue('menu.extra.pageBoundary.Last Page', 'en', 'Last Page');

for (const [locale, labels] of Object.entries(menuTabs.MENU_TAB_LABELS)) {
  menuTabs.MENU_TAB_KEYS.forEach((key, index) => setValue(`menu.tabs.${key}`, locale, labels[index]));
}

// Fill shared desktop keys that the native iOS UI uses but older desktop
// locale tables omit. Keep these in source so regeneration is lossless.
const sharedExtras = JSON.parse(await readFile(join(repoRoot, 'tools/ios-shared-strings.json'), 'utf8'));
for (const [key, messages] of Object.entries(sharedExtras)) {
  if (!values.has(key)) throw new Error(`Unknown shared localization key: ${key}`);
  for (const [locale, value] of Object.entries(messages)) {
    if (!(locale in locales)) throw new Error(`Unknown locale: ${locale}`);
    // Prefer upstream translations when the desktop catches up.
    if (!(locale in values.get(key))) setValue(key, locale, value);
  }
}

// ReaderCore substitutes numbered brace placeholders itself, after lookup.
const coreErrors = JSON.parse(await readFile(join(repoRoot, 'tools/core-error-strings.json'), 'utf8'));
for (const [template, messages] of Object.entries(coreErrors)) {
  for (const [locale, value] of Object.entries(messages)) setValue(`core.error.${template}`, locale, value);
}

const placeholderPattern = /\{([A-Za-z0-9_.-]+)\}/g;
function placeholderNames(template) {
  const names = [];
  for (const match of template.matchAll(placeholderPattern)) {
    if (!names.includes(match[1])) names.push(match[1]);
  }
  return names;
}

function formatValue(value, source) {
  const names = placeholderNames(source);
  for (const name of placeholderNames(value)) if (!names.includes(name)) names.push(name);
  if (!names.length) return value;

  const sentinels = names.map((_, index) => `\u0000L10N${index}\u0000`);
  let formatted = value.replace(placeholderPattern, (placeholder, name) => {
    const index = names.indexOf(name);
    return index < 0 ? placeholder : sentinels[index];
  });
  formatted = formatted.replaceAll('%', '%%');
  sentinels.forEach((sentinel, index) => {
    formatted = formatted.replaceAll(sentinel, `%${index + 1}$@`);
  });
  return formatted;
}

const strings = {};
let fallbackCount = 0;
for (const key of [...values.keys()].sort()) {
  const translations = values.get(key);
  const source = translations.en ?? key;
  const localizations = {};
  for (const locale of Object.keys(locales)) {
    const translated = locale in translations;
    const value = translated ? translations[locale] : source;
    if (!translated) fallbackCount += 1;
    localizations[locale] = {
      stringUnit: { state: translated ? 'translated' : 'needs_review', value: key.startsWith('core.error.') ? value : formatValue(value, source) },
    };
  }
  strings[key] = { localizations };
}

const catalog = {
  sourceLanguage: 'en',
  strings,
  version: '1.0',
};
await writeFile(output, `${JSON.stringify(catalog, null, 2)}\n`);

// Parse the file that was actually written as a final guard against an
// incomplete export or an encoding mistake.
JSON.parse(await readFile(output, 'utf8'));
console.log(
  JSON.stringify({
    output,
    keys: Object.keys(strings).length,
    locales: Object.keys(locales).length,
    localeCodes: Object.keys(locales),
    fallbackLocalizations: fallbackCount,
  }),
);

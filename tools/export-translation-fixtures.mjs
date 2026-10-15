import { createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = resolve(fileURLToPath(new URL('..', import.meta.url)));
const desktop = process.env.PDFMATHREADER_DESKTOP_ROOT || '/Users/rongxin/Developer/oss/PDFMathReader';

const {
  hasRichTextPlaceholders,
  hasUnparsedPlaceholders,
  stripRichTextPlaceholders,
} = await import(join(desktop, 'shared/translation/rich-text-placeholders.mjs'));
const { restoreFormulaPlaceholders } = await import(
  join(desktop, 'src/features/translation/formula-placeholders.mjs'),
);
const { glossaryEntries, protectTerms } = await import(join(desktop, 'shared/translation/glossary.mjs'));
const { kernelTranslationSpacing, paragraphDisplayText, translationSpacing } = await import(
  join(desktop, 'shared/translation/spacing.mjs'),
);
const {
  LANGUAGE_CODES,
  isCustomLanguageCode,
  isTranslationLanguageSupported,
  normalizeTranslationLanguage,
  translationLanguagesForKernel,
} = await import(join(desktop, 'shared/translation/languages.mjs'));
const { createTranslationProvider, FREE_ENDPOINTS } = await import(
  join(desktop, 'server/translation/translation-provider.mjs'),
);

const stable = (value) =>
  Array.isArray(value)
    ? value.map(stable)
    : value && typeof value === 'object'
      ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]))
      : value;

const stableJSON = (value) => JSON.stringify(stable(value));
const hash = (value) => createHash('sha256').update(value).digest('hex');

function paragraphCacheKey({ text, language, sourceLanguage, model, service, glossary = [], cacheScope = '' }) {
  return hash(
    stableJSON({
      text,
      language,
      ...(sourceLanguage && sourceLanguage !== 'English' ? { sourceLanguage } : {}),
      model,
      ...(service ? { service } : {}),
      prompt: 1,
      ...(glossary.length ? { glossary } : {}),
      ...(cacheScope ? { cacheScope } : {}),
    }),
  );
}

function compatibleParagraphCacheKey({ text, language, sourceLanguage, glossary = [], cacheScope = '' }) {
  return hash(
    stableJSON({
      text,
      language,
      ...(sourceLanguage && sourceLanguage !== 'English' ? { sourceLanguage } : {}),
      compatible: 1,
      prompt: 1,
      ...(glossary.length ? { glossary } : {}),
      ...(cacheScope ? { cacheScope } : {}),
    }),
  );
}

function providerCacheKey({ service, baseUrl, model, body, cacheScope = '' }) {
  return hash(
    stableJSON({
      version: 1,
      ...(cacheScope ? { cacheScope } : {}),
      service,
      ...(baseUrl ? { baseUrl } : {}),
      model,
      body,
    }),
  );
}

const jsonResponse = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });

async function captureRequest(provider, body) {
  const calls = [];
  const fetcher = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    if (String(url).endsWith('/check')) return jsonResponse({ status: 'ok' });
    if (String(url).endsWith('/config')) return jsonResponse({ status: 'ok', qps: 100 });
    return provider.id === 'siliconflow-free'
      ? jsonResponse({ content: '译文' })
      : jsonResponse({ choices: [{ message: { role: 'assistant', content: 'translation' } }] });
  };
  const client = createTranslationProvider(fetcher, { retryDelay: () => 0 });
  await client.complete(provider, body, new AbortController().signal, { cache: false });
  const completion = calls.findLast((call) => call.url.endsWith('/chat/completions') || FREE_ENDPOINTS.includes(call.url));
  return {
    calls: calls.map((call) => ({
      url: call.url,
      headers: call.options.headers || {},
      body: call.options.body ? JSON.parse(call.options.body) : null,
    })),
    completionBody: completion?.options.body ? JSON.parse(completion.options.body) : null,
  };
}

const glossaryLibraries = [
  {
    id: 'a',
    name: 'Research',
    enabled: true,
    entries: [
      { source: 'effect', target: '效应' },
      { source: 'treatment effect', target: '处理效应' },
      { source: 'C++', target: '$&术语' },
    ],
  },
  { id: 'disabled', name: 'Disabled', enabled: false, entries: [{ source: 'effect', target: '错误' }] },
];
const glossary = glossaryEntries(glossaryLibraries);
const protectedGlossary = protectTerms('treatment effect and effect; C++ PMRGLOSSARY0END', glossary);

const openAIProvider = {
  id: 'openai',
  model: 'gpt-4.1-mini',
  key: 'fixture-key',
  baseUrl: 'https://example.test/v1',
};
const openAIInput = {
  model: 'caller-model',
  messages: [
    { role: 'system', content: 'Keep the formula notation {v*} unchanged.' },
    { role: 'user', content: 'Energy {v0} in 中文' },
  ],
  response_format: { type: 'text' },
};
const freeProvider = {
  id: 'siliconflow-free',
  model: 'siliconflow-free',
  language: 'Simplified Chinese',
};
const freeInput = {
  messages: [{ role: 'user', content: 'Translate formally into Chinese:\n\nHi 中文 {v0}' }],
  response_format: { type: 'json_object' },
};
const fastTemplateInput = {
  messages: [{
    role: 'user',
    content:
      'You are a professional, authentic machine translation engine. Only Output the translated text, do not include any other text.\n\nTranslate the following markdown source text to zh. Keep the formula notation {v*} unchanged. Output translation directly without any additional text.\n\nSource Text: Energy {v0}\n\nTranslated Text:',
  }],
};
const fastProvider = { ...freeProvider, kernel: 'pdf_math_fast', language: 'zh' };

const openAIRequest = await captureRequest(openAIProvider, openAIInput);
const freeRequest = await captureRequest(freeProvider, freeInput);
const fastRequest = await captureRequest(fastProvider, fastTemplateInput);
const routeInput = {
  text: 'Energy {v0} 中文',
  language: 'Simplified Chinese',
  sourceLanguage: 'French',
  model: 'gpt-4.1-mini',
  service: { service: 'openai', baseUrl: 'https://example.test/v1', model: 'gpt-4.1-mini' },
  glossary: [{ source: 'Energy', target: '能量' }],
  cacheScope: 'documenthash:3',
};
const providerBody = openAIRequest.completionBody;

const fixtures = {
  version: '0.1.11',
  languages: {
    codes: LANGUAGE_CODES,
    custom: ['en', 'pt-BR', 'zh-Hant', ' en', 'en ', 'en US', ''],
    support: [
      ['pdf_inspector', 'Simplified Chinese'],
      ['pdf_math_fast', 'French'],
      ['pdf_math_fast', 'Arabic'],
      ['pdf_math_precise', 'Arabic'],
      ['pdf_math_precise', 'zh-Hant'],
    ].map(([engine, language]) => ({
      engine,
      language,
      supported: isTranslationLanguageSupported(engine, language),
    })),
    normalized: [
      ['pdf_math_fast', 'Arabic', 'English'],
      ['pdf_math_precise', 'Arabic', 'English'],
      ['pdf_inspector', 'missing', 'English'],
    ].map(([engine, language, fallback]) => ({
      engine,
      language,
      fallback,
      output: normalizeTranslationLanguage(engine, language, fallback),
    })),
    kernels: ['pdf_inspector', 'pdf_math_fast', 'pdf_math_precise'].map((engine) => ({
      engine,
      target: translationLanguagesForKernel(engine),
      source: translationLanguagesForKernel(engine, 'source'),
    })),
  },
  glossary: {
    entries: glossary,
    protected: protectedGlossary.text,
    restored: protectedGlossary.restore(protectedGlossary.text),
  },
  spacing: [
    'English中文',
    '中文English',
    'A1中文',
    '中文42',
    'e\u0301中文',
    '  中文段落\n  English paragraph',
  ].map((input) => ({ input, output: translationSpacing(input), display: paragraphDisplayText(input) })),
  kernelSpacing: [
    '{"a":"English中文","nested":["中文English",3],"formula":"{v0}"}',
    'not json 中文English',
  ].map((input) => ({ input, output: kernelTranslationSpacing(input) })),
  placeholders: [
    "<样式 id='1'>谁</样式>: 将<style id=\"2\">媒体干扰</ style>作为处理变量",
    'x < y and y > z',
    '<code id="2">x</code>',
    '见 {v*}',
    '见 {{v3}}',
    "<style id='1'>谁</style>",
    '见 {v1}',
  ].map((input) => ({
    input,
    has: hasRichTextPlaceholders(input),
    stripped: stripRichTextPlaceholders(input),
    unparsed: hasUnparsedPlaceholders(input),
  })),
  formulaPlaceholders: [
    { translation: 'A {v0}', formulaTexts: ['FORMULA'], sourceInput: '{v0}' },
    { translation: 'A {{v1}}', formulaTexts: ['F0', 'F1'], sourceInput: '{{v1}}' },
    { translation: 'A {v*}', formulaTexts: ['FORMULA'], sourceInput: '{v0}' },
    { translation: 'A {v*}', formulaTexts: ['F0', 'F1'], sourceInput: '{v0} {v1}', text: 'original' },
  ].map((input) => ({
    ...input,
    output: restoreFormulaPlaceholders(input).translation,
  })),
  requestBodies: [
    { provider: 'openai', input: openAIInput, ...openAIRequest },
    { provider: 'siliconflow-free', input: freeInput, ...freeRequest },
    { provider: 'siliconflow-free-fast-template', input: fastTemplateInput, ...fastRequest },
  ],
  cacheKeys: {
    paragraph: paragraphCacheKey(routeInput),
    compatibleParagraph: compatibleParagraphCacheKey(routeInput),
    provider: providerCacheKey({
      service: 'openai',
      baseUrl: 'https://example.test/v1',
      model: 'gpt-4.1-mini',
      body: providerBody,
      cacheScope: 'documenthash:3',
    }),
  },
};

const output = join(repo, 'Packages/ReaderCore/Tests/ReaderCoreTests/Fixtures/translation/translation-fixtures.json');
await mkdir(join(repo, 'Packages/ReaderCore/Tests/ReaderCoreTests/Fixtures/translation'), { recursive: true });
await writeFile(output, JSON.stringify(fixtures, null, 2) + '\n');
console.log(`wrote ${output}`);

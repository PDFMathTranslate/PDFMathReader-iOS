# Interface localization

The iOS interface supports the same 16 languages as desktop. Select a language
under Settings → Appearance → Interface language. The change applies immediately
across open library and reader windows and persists in reader preferences.
“System” follows the device's preferred language. Arabic, Egyptian Arabic, and
Urdu use right-to-left layout. Translation source and target languages remain
separate from the interface language.

`App/Sources/Localization/L10n.swift` resolves interface language choices and
loads the selected compiled string table with English fallback. Legacy Chinese
script identifiers are accepted alongside desktop's `zh-CN` and `zh-TW` codes.

## Translation sources

- Desktop locale tables supply shared labels.
- `tools/ios-strings.json` supplies iOS-specific labels in all 16 languages.
- `tools/ios-shared-strings.json` fills shared translations missing upstream.
  Upstream translations take precedence when they become available.
- `tools/companion-strings.json` supplies native computer-document controls.
- `tools/core-error-strings.json` supplies ReaderCore error templates.
- `App/Resources/InfoPlist.xcstrings` localizes the local-network permission text.
  iOS controls the language and presentation of system permission dialogs.

Regenerate the main catalog after editing its sources:

```sh
node tools/export-localizations.mjs
```

The exporter defaults to `/Users/rongxin/Developer/oss/PDFMathReader`; set
`PDFMATHREADER_DESKTOP_ROOT` to use another desktop checkout.

Run the checks:

```sh
node tools/check-ios-strings-complete.mjs
node tools/check-ios-localization.mjs
node tools/check-ios-info-localization.mjs
node tools/check-core-error-localization.mjs
```

The source checker includes catalog keys stored in Swift option arrays and
switches. It checks every supported language for each referenced key and
verifies format placeholders. `LocalizationTests` covers language resolution,
compiled translations, fallback, formatting, and live language updates. `LocalizationUITests` checks switching between German,
Arabic, and English and persistence after relaunch.

ReaderCore errors use `ReaderLocalization` with English defaults. The app installs
a resolver at startup, so errors use the active interface language. Numbered brace
placeholders are substituted by ReaderCore after lookup; they deliberately remain
unconverted in the generated catalog. External server and framework diagnostics
retain their supplied text.

After adding resources or test files, run `xcodegen generate` before building.

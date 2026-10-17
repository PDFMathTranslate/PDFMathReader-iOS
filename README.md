# PDFMathReader for iOS

Read scientific documents on iPhone and iPad with translation, annotations, and Apple Pencil support. A native SwiftUI and PDFKit companion to [PDFMathReader for desktop](https://github.com/PDFMathTranslate/PDFMathReader), powered by [PDFMathTranslate](https://github.com/PDFMathTranslate/PDFMathTranslate).

![PDFMathReader on iPad](docs/screenshots/ipad.png)

<details>
<summary>iPhone screenshot</summary>

<img src="docs/screenshots/iphone.png" alt="PDFMathReader on iPhone" width="360">

</details>

## Features

- **Translate while reading:** translate nearby pages or the full document, switch between original and translated content, and reuse cached translations.
- **Translation options:** use Apple on-device translation, the built-in free service, an OpenAI-compatible endpoint, or translation kernels shared by your computer.
- **Flexible reading:** thumbnails, outlines, search, horizontal or vertical scrolling, page layouts, fit-to-page and fit-to-width zoom, page cropping, reduced padding, and automatic page-width alignment.
- **Multiple documents:** switch between tabs and restore reading positions and document settings from Recents.
- **Highlights and comments:** annotate passages and create bidirectional quick links between reading locations.
- **Apple Pencil:** draw with the native PencilKit palette, with optional finger drawing and editable drawings preserved in exported PDFs.
- **PDF and EPUB import:** open files from Files or other apps. EPUB books are converted into paginated PDFs on device.
- **Computer documents:** pair with the desktop app to open a computer PDF, carry over reading progress and annotations, and save changes back when closing it.
- **Portable exports:** share original or translated PDFs, including annotations and drawings, through the system share sheet or AirDrop.
- **Localized interface:** choose from the same 16 interface languages as desktop, including right-to-left layouts.

## Quick start

The app targets **iOS and iPadOS 18 or later**. To install from source, follow [Local development](#local-development) below and run the app on your device through Xcode.

1. Choose **Import PDF or EPUB** in the library, or send a document from another app using **Share** or **Open In → PDFMathReader**.
2. In **Settings**, choose a translation engine, service, and source/target languages. For a custom OpenAI-compatible service, enter its endpoint, model, and API key.
3. Open the document and use the toolbar to switch original/translated content, search, annotate, or open drawing tools. The More menu contains reading, layout, and translation controls.
4. Close the document to return to the library. For computer documents, keep the connection available until saving finishes.

### Translation engines

| Engine | Processing | Requirements |
| --- | --- | --- |
| Ultra Fast | Local layout extraction and translated text overlays | Apple on-device translation, the built-in free service, or an OpenAI-compatible service |
| Fast | PDFMathTranslate kernel shared by a computer | Paired desktop app with kernel sharing enabled |
| Precise | Remote PDF translation | A compatible computer kernel or configured remote translation server |

Apple translation requires iOS/iPadOS 26 or later and supported languages with downloaded language models. Network services have their own availability, credentials, and usage limits. See [Computer pairing](docs/COMPUTER-PAIRING.md) for desktop kernel setup and service selection.

### Read across devices

Enable **Auto-discovery** and **Share Kernels with iPhone and iPad** in the desktop app, then use **Find Nearby Computers** in iOS Settings and enter the computer's pairing code. Keep the desktop app open and the computer awake. Manual addresses and remembered Tailscale endpoints are also supported.

To continue a computer document, close it on the computer first, then select it under **On Your Computer** in the iOS library. The computer reserves the document for that iOS session until saving and closing complete. See [Computer documents](docs/COMPUTER-DOCUMENTS.md) for ownership, reconnection, and save behavior.

## Documentation

| Guide | Topics |
| --- | --- |
| [Computer pairing](docs/COMPUTER-PAIRING.md) | Local discovery, pairing codes, Tailscale, and shared translation services |
| [Computer documents](docs/COMPUTER-DOCUMENTS.md) | Document handoff, annotations, save checkpoints, and reconnecting |
| [Apple Pencil](docs/APPLE-PENCIL.md) | Drawing tools, finger input, saving, and editable PDF exports |
| [EPUB](docs/EPUB.md) | On-device conversion, supported content, and limitations |
| [Tabs](docs/TABS.md) | Opening, switching, and closing documents |
| [Sharing and AirDrop](docs/AIRDROP.md) | Import, portable PDFs, annotations, quick links, and transfer checks |
| [Localization](docs/LOCALIZATION.md) | Interface languages, string generation, and validation |

## Development

### Local development

Requirements: macOS, Xcode with the iOS SDK and Swift 6 support, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Node.js is needed only for localization tools and fixture exporters; it is not an app runtime dependency.

```sh
git clone https://github.com/PDFMathTranslate/PDFMathReader-iOS.git
cd PDFMathReader-iOS
brew install xcodegen
xcodegen generate
open PDFMathReader.xcodeproj
```

Choose the **PDFMathReader** scheme and an iPhone or iPad simulator, then run. For a physical device, select your own development team under **Signing & Capabilities**, connect the device, and run from Xcode.

`project.yml` is the source of truth for project configuration. The generated `.xcodeproj` is ignored by Git; regenerate it after adding source files or resources or changing the project specification. The app uses the local `Packages/ReaderCore` Swift package.

### Tests and checks

Run the core package tests on macOS:

```sh
swift test --package-path Packages/ReaderCore
```

Run app tests against an installed simulator. Substitute an available device from `xcrun simctl list devices available`:

```sh
xcodegen generate
xcodebuild test \
  -project PDFMathReader.xcodeproj \
  -scheme PDFMathReader \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PDFMathReaderTests
```

UI tests live in `App/UITests`. Some require prepared PDF fixtures, a configured service, or a physical device; check the individual test's setup before running them. Simulator tests cannot establish Apple Pencil hardware behavior or successful AirDrop delivery.

Check localization with:

```sh
node tools/check-ios-strings-complete.mjs
node tools/check-ios-localization.mjs
node tools/check-ios-info-localization.mjs
node tools/check-core-error-localization.mjs
```

Localization and desktop-parity fixture exporters can read a separate desktop checkout through `PDFMATHREADER_DESKTOP_ROOT`. See [Localization](docs/LOCALIZATION.md) and the fixture READMEs under `Packages/ReaderCore/Tests/ReaderCoreTests/Fixtures` before regenerating them.

### Architecture

- **`App/Sources`** contains the SwiftUI library, settings, PDFKit reader, PencilKit integration, translation overlays, and desktop connection flows.
- **`Packages/ReaderCore`** contains document state, layout extraction, translation providers and scheduling, caches, annotations, EPUB parsing, and portable PDF export logic.
- **`App/Tests` and `App/UITests`** cover app integration and reader interactions; package tests cover the shared core.
- **`tools`** contains localization, fixture, and icon generation scripts.

The iOS app renders PDFs natively. Ultra Fast extracts page content locally and draws translation overlays; Fast and Precise delegate kernel work to a computer or server rather than installing desktop Python environments on the device.

### Data and privacy

Ultra Fast network services receive document text; Apple on-device translation uses Apple's translation framework. Fast and Precise send individual PDF pages to the configured computer or remote kernel. Choose a service appropriate for the documents you read.

The iOS OpenAI-compatible API key and computer pairing code use the system Keychain; credentials for shared computer services remain on the computer. Reading state, translation caches, and drawing data are retained locally and may contain document content. Files opened in place keep security-scoped references; documents received through Share or Open In are copied into app storage. Computer-document sessions checkpoint edits and retain pending saves locally when disconnected; reconnect and finish closing the document to release its desktop session.

### Limitations

- Translation and layout fidelity depend on the document and selected engine. Complex tables, equations, scanned pages, and unusual typography can require a different engine or manual review.
- Fast requires a reachable paired computer. Precise can use a compatible remote server or paired computer. If kernel translation is unavailable or fails, the reader can fall back to Ultra Fast. Desktop features are not all available on iOS.
- EPUB import produces a fixed-layout PDF; it is not a reflowable EPUB reader and does not export edited EPUBs. DRM-protected books are unsupported.
- Computer-document ownership applies to the paired workflow. Exported copies and changes made in other PDF apps are independent.
- AirDrop creates a portable copy; it does not continuously synchronize that copy with the sender.

## Paper

The underlying PDFMathTranslate work appeared in **EMNLP 2025: System Demonstrations**. See the [paper and citation](https://aclanthology.org/2025.emnlp-demos.71/) or the [desktop README](https://github.com/PDFMathTranslate/PDFMathReader#paper) for the full reference.

## Acknowledgements

Built on Apple's SwiftUI, PDFKit, PencilKit, WebKit, Vision, and Translation frameworks, alongside [PDFMathTranslate](https://github.com/PDFMathTranslate/PDFMathTranslate), [PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next), and the desktop PDFMathReader project. Bundled page-width alignment resources retain their [upstream license notice](App/Resources/PDFWidthAlignment/LICENSE.md).

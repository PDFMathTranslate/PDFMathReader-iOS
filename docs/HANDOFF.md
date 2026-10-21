# Native Handoff

Both apps register `org.pdfmathreader.reading`. iOS publishes an eligible
`NSUserActivity` for the visible PDF after a complete snapshot has been saved to
the paired computer. macOS uses Electron's native user-activity integration to
publish and receive the same activity, including launch from a closed app.

## Setup

Install builds signed by the same Apple developer team on both devices. Sign in
to the same Apple Account, enable Handoff, Wi-Fi, and Bluetooth, and keep the
devices nearby. In PDFMathReader, enable the Mac companion service and pair iOS
with that computer. The configured computer must be reachable from iOS.

Open a PDF and allow its snapshot to finish saving. The receiving Mac's Dock can
then show the system Handoff icon. Select it to continue the document. To go in
the other direction, open the paired computer's PDF on the Mac and use the
system Handoff suggestion on iOS. The operating system controls when and where
the suggestion appears; a simulator cannot verify nearby-device discovery.

## Preserved state

The portable PDF contains the source document, editable highlights and comments,
quick-link records and native PDF destination links, reading state, and iOS
drawings. The activity includes the document identity and current page. On
receipt, the app restores the transferred metadata and opens that page.

Handoff uses the authenticated companion document transport for PDF bytes.
Activity metadata contains no pairing credential, PDF bytes, or local file
path. iOS uses its configured paired computer and stored credential; an address
provided by another device's activity cannot redirect that credential.

Edits withdraw the advertised activity until a fresh snapshot is committed.
Active companion documents use exclusive edit sessions. On continuation, the
source saves and releases its session before the recipient takes ownership.
The recipient waits briefly for that release and never forces a lock takeover.
iOS-local PDFs are imported once, then updated with revision checks; a changed
desktop copy prevents an overwrite. Durable journals replay the exact pending
request after a lost response before accepting another version.

## Device check

1. Open a two-page PDF on iOS. Add and edit a comment, delete another annotation,
   add a quick link between pages, and navigate to page two.
2. Wait for the Mac Dock's Handoff suggestion and select it.
3. Confirm the correct document and page, edited comment, deleted annotation,
   and both quick-link endpoints on the Mac.
4. Change a comment and reading page on the Mac, then continue on iOS.
5. Confirm the changes and that the previous source no longer owns the session.
6. Disconnect the network during a save and retry; confirm one imported document
   and no overwritten newer desktop edits.

Passing build and transport tests does not establish that Apple's nearby-device
discovery displayed a Dock icon. That requires the two physical devices and
their Apple Account and system settings.

## Publication diagnostics

iOS writes the latest lifecycle status to
`Library/Application Support/PDFMathReader/Handoff/diagnostic.json` and the
`Handoff` OSLog category. `idle` means no reader is selected; `preparing` means
the portable snapshot is being saved; `published` means `becomeCurrent()` was
called after that save. `failed` includes a bounded error category without
credentials or document contents. Publication alone still requires observing
the receiving device's system suggestion.

PDF annotation scanning compares bytes in place, and portable snapshot export
runs on a utility worker. A physical iPad exposed a main-thread scene-update
watchdog termination in this path; background export keeps scene transitions
responsive while preparing a Handoff snapshot.

`NSUserActivityDelegate` callbacks are nonisolated: Foundation can call them on
its activity queue. The save callback only clears `needsSave`; continuation
passes the activity identity into a main-actor task before changing reader
state. A physical-device crash exposed the earlier main-actor assumption.
A regression invokes both delegate methods from a detached task.

Transport failures additionally write bounded domain/code diagnostics to
`Handoff/transport-error.json`, excluding cancellations, URLs, credentials,
headers, and raw error userInfo.

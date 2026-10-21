# Send a document to a computer

## Receive a PDF on iPhone or iPad

In another app, select a PDF and choose **Share** or **Open In**, then choose
**PDFMathReader**. Incoming PDFs open from either the library or an existing
reader window. The app saves a local copy so the document remains available in
Recents after the sending app removes its temporary file. Invalid or unreadable
files show an error without replacing the currently open document.

## Send a PDF

Open a PDF, open the reader's menu, and choose **AirDrop to Computer**.
In the system share sheet, select **AirDrop** and the receiving Mac. The Mac
must have AirDrop receiving enabled. This shares a newly generated PDF file;
it does not share a device-local file path or require a translation server.

The portable PDF contains:

- Native PDF highlights and comments, including their editable reader metadata.
- A pair of PDF destination links for each quick link, so both directions work
  in a PDF viewer that supports internal links, including macOS Preview.
- Versioned reader metadata containing the complete quick-link records and
  reading position. A receiving PDFMathReader iOS installation restores these
  without replacing its existing local quick-link edits or reading progress.

The AirDrop action shares the original document with current annotations and
quick links. It does not flatten translated text into the document. The separate
**Export Translated PDF** action remains available for a translated copy.

The desktop companion source in `PDFMathReader` now imports transfer quick links
through its annotation import pipeline. This requires a desktop build containing
that change; existing installed releases do not automatically gain the importer.
An empty local quick-link sidecar remains authoritative, so importing a PDF never
resurrects deliberately deleted local links.

Received PDFs carry a stable transfer identifier so editing comments does not
orphan the iOS recipient's local links and reading position when PDF bytes change.

PDF viewers differ in how they display link hit areas and comment popovers.
The sender's PDF remains open and unchanged. Changes to the received copy do
not synchronize back to the sender.

## Native Handoff

Native `NSUserActivity` Handoff is also supported. See [Native Handoff](HANDOFF.md)
for pairing, signing, and device requirements. AirDrop remains an independent
way to send a portable copy through the system share sheet.

See [Apple's Handoff documentation](https://developer.apple.com/documentation/foundation/implementing-handoff-in-your-app).

## Physical-device verification

AirDrop discovery cannot be verified in an iOS simulator. On an iPhone or iPad:

1. Add a highlight, a comment, and a quick link between two different pages.
2. Edit the comment, delete another annotation, and navigate to a later page.
3. Choose **AirDrop to Computer**, then select a Mac in the system sheet.
4. Open the received PDF in Preview. Check highlights, the edited comment,
   absence of the deleted annotation, and links in both directions.
5. Send the received PDF to PDFMathReader on another iOS device. Check the
   quick-link list, both endpoint destinations, and restored reading page.
6. Delete all received quick links, close and reopen the same file, and verify
   they remain deleted.

A completed PDF export is not proof that an AirDrop recipient accepted the file.

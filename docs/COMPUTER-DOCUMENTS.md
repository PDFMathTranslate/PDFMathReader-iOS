# Read a computer document on iPhone or iPad

Pair the computer in Settings first (see [Computer pairing](COMPUTER-PAIRING.md)). Both apps must include document sharing support, and the computer must remain awake with sharing enabled.

In the iOS library, choose **On Your Computer**, refresh the recent-document list, then tap a PDF. Close that PDF on the computer before opening it on the phone or tablet. A toast explains when another reader owns it.

The handoff downloads the whole PDF, including highlights and comments stored separately by the desktop reader, quick links, and reading position. PDFs up to 200 MiB are supported. The client verifies the byte count, SHA-256 checksum, and every PDF page before opening it. Editable iOS Pencil drawings travel in the portable PDF too; other viewers can display their embedded appearance.

The computer holds an exclusive document session until iOS successfully saves and closes it. The app checkpoints while reading and when backgrounded. Use the reader's **Close Document** action or close its tab to finish the handoff; merely switching tabs or backgrounding the app keeps ownership. Another device cannot open the same computer document while this session remains open.

If the connection fails, edits remain on the iOS device. Reconnect and retry closing. If the computer may have accepted a close but its acknowledgement was lost, editing pauses until the save is confirmed. The exact upload is journaled and retried rather than regenerated. Restarting either app does not silently discard ownership, and an old computer-backed Recent entry reconnects rather than opening an offline copy outside its session.

The session protects documents opened through PDFMathReader's paired-computer workflow. Separately exported copies and edits made by other PDF applications are independent; external changes to the computer's original must be treated as a conflict rather than overwritten.

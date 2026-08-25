# Nothing Personal: I built a local PDF redactor

I needed to send financial documents to a tax strategist. They needed the institutions, holdings, transactions, and amounts. They did not need my names, addresses, tax IDs, phone numbers, or account numbers.

Preview can redact a PDF, but I had to find every occurrence myself. The same PII appeared across dozens of pages with different capitalization and formatting.

I built [Masker](https://github.com/cpatil/masker), a native macOS app that finds those repetitions and lets me review them before export. It runs locally. Scanned pages use Apple's on-device OCR.

![Masker reviewing a generated Joe Farmer tax return](joe-farmer-overview.png)

*The screenshots use a generated Joe Farmer tax return, not a real financial document.*

## The workflow

1. Enter the PII to mask.
2. Scan the PDF.
3. Review each proposed mask and uncheck false positives.
4. Search for anything missed, add it, and rescan.
5. Export a sanitized copy.

Masker also detects SSNs, EINs, email addresses, phone numbers, and account suffixes. It can keep an institution name visible while covering only its account number.

The PDF stays scrollable during review. Clicking a black box selects the corresponding match in the list.

![Searching for a synthetic name that was not in the original mask set](joe-farmer-search.png)

Search ignores text already covered by a selected mask. Here it finds a synthetic dependent name that I had not added yet.

## Labels when black boxes are not enough

A tax strategist may need to tell two people or two accounts apart. A mask can carry a label such as `Client-1` or `Account-2`.

![Synthetic taxpayers and SSNs replaced with labels](joe-farmer-labels.png)

The value-to-label mapping exports as JSON. It can be imported for another PDF without storing page numbers, coordinates, filenames, or paths.

## Folders

Discovery Mode walks a folder of PDFs while I build one shared mask set. Batch Convert applies an exported set to every PDF under a folder and preserves its directory structure. Each input produces a separate sanitized PDF.

There is also an optional MCP companion. It reports opaque document IDs and progress counts; it does not receive PDFs, filenames, paths, PII, mask values, or labels.

## Export and testing

The export rebuilds every page from sanitized pixels. The original PDF text is not copied into the output.

This app was vibe-coded with Codex. Its tests use generated PDFs, including the Joe Farmer return above. They cover text PDFs, scanned pages, rotated pages, overlapping matches, labels, imports, rescans, folder discovery, and batch conversion. Exported files are checked again with text extraction and OCR.

Masker is open source. Download the universal Apple Silicon/Intel build from the [latest release](https://github.com/cpatil/masker/releases/latest).

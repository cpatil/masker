# I built a local PDF redactor because Preview made me click too much

I needed to share financial documents with a tax strategist. Preview can redact PDFs, but selecting the same names, addresses, tax IDs, and account numbers on every page got old quickly.

So I built [Masker](https://github.com/cpatil/masker), a native macOS app for reviewing and permanently masking repeated values. It runs locally with PDFKit and Apple's on-device OCR. There is no account, server, or upload.

![Masker reviewing masks in the generated Joe Farmer tax return](joe-farmer-overview.png)

Masker can:

- Match exact values case-insensitively and on word boundaries.
- Prefer the longest match when values overlap.
- Find SSNs, EINs, emails, phone numbers, and account suffixes.
- Keep institution names visible while masking only account identifiers.
- Search incrementally for anything the automatic scan missed.
- Review a continuously scrolling PDF and jump between masks and their rows.
- Use black boxes or optional replacement labels such as `Client-1`.
- Save recent PDFs and export reusable values and labels as JSON.

![Incremental search finding an unmasked name in the Joe Farmer fixture](joe-farmer-search.png)

![Replacement labels rendered inside masks for two distinct people](joe-farmer-labels.png)

Exported pages are rebuilt from sanitized pixels at 300 DPI. The original text layer, forms, annotations, attachments, scripts, and metadata are not copied.

This was vibe-coded with Codex. The tests use generated PDFs, including the fake Joe Farmer return shown above. They cover searchable and scanned documents, rotated pages, overlapping matches, account suffixes, labels, JSON import/export, and rescan behavior. The exported PDF is checked again with text extraction and OCR to make sure selected values are gone.

Masker is open source, with a universal Apple Silicon/Intel build available on [GitHub](https://github.com/cpatil/masker/releases/latest).

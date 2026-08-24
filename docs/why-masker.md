# I built a local PDF redactor because Preview made me click too much

I needed to share a pile of financial documents with a tax strategist and had a predictable problem: the same names, addresses, SSNs, and account numbers appeared over and over.

Preview on macOS has a real redaction tool, but I still had to find and select every occurrence by hand. I wanted the computer to do the repetitive search while leaving the final decision to me.

That became [Masker](https://github.com/cpatil/masker), a small native macOS app. You add PDFs, enter values to remove, review every suggested mask, and export sanitized copies. Everything runs locally using PDFKit and Apple's Vision OCR. There is no account, server, or upload.

Masker was vibe-coded with Codex. The process was simple: describe the next piece, try it on the documents in front of me, find what broke, and turn that failure into a test.

PDFs supplied plenty of failures. `FORM 8879` looked like an account number. Account suffixes appeared in a different text order from the table visible on the page. An 89-page image-only PDF made incremental search feel endless because each keystroke restarted OCR.

Those cases shaped the app. Form numbers and years are excluded from account matching. Page geometry lets Masker cover an account suffix while keeping the institution name and amount visible. OCR is cached, stale searches are cancelled, and search results omit text that is already masked.

The test suite generates its own searchable, scanned, and rotated PDFs. It covers formatted and compact identifiers, shortened names such as `JOE AND MARY FARMER` to `Joe Farmer`, institution rows, and false positives. After export, it opens the sanitized PDF again and searches it using both text extraction and OCR. The test fails if a selected value is still recoverable.

Export is intentionally blunt: each page is rebuilt from sanitized pixels at 300 DPI. That produces a larger, non-searchable PDF, but it avoids leaving the original text behind a black rectangle.

Masker solved the problem I built it for. The source and a universal Apple Silicon/Intel build are available on [GitHub](https://github.com/cpatil/masker/releases/latest).

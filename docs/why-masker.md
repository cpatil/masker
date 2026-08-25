# Nothing Personal: I built a local PDF redactor

I needed to share a folder of financial documents with a tax strategist. They needed the financial picture—the institutions, holdings, transactions, and amounts—but not the personally identifiable information (PII) threaded through every document.

That PII was not confined to a cover page. The same names, addresses, tax IDs, phone numbers, and account numbers appeared again and again, sometimes with different capitalization or formatting. Preview can permanently redact a PDF, but I still had to find and select every occurrence by hand.

I built [Masker](https://github.com/cpatil/masker) to find the repetitions while leaving the final decision to me. It is a native macOS app, and scanned pages use Apple's on-device OCR. Nothing is uploaded.

## Finding PII without hiding the useful parts

The distinction matters. A tax strategist may need to see that an account is at a particular bank or brokerage, but not its identifying suffix. Masker can leave `EXAMPLE BANK` and the amount visible while covering the account number. It can also find formatted and unformatted versions of the same SSN or EIN.

I enter the PII I already know about, run the scan, and review the proposed masks while scrolling through the full PDF. Clicking a mask selects its row, and any false positive can be unchecked before export.

![Full Masker review screen showing a generated Joe Farmer tax return, the shared mask options, per-page matches, and the continuously scrolling PDF](joe-farmer-overview.png)

*Reviewing a generated Joe Farmer return. No real financial document is used in these screenshots.*

Matches are case-insensitive and stop at word boundaries. Longer overlapping values take precedence.

## Looking for what I missed

My bigger concern was missed PII. The search box lets me try a surname, street number, or account suffix and move through the remaining visible results. Matches already covered by a selected mask stay out of the search results. If I find something new, I add it and rescan.

![Incremental search finding the still-visible synthetic dependent name Jimmy Farmer while already-selected masks are omitted](joe-farmer-search.png)

*A search catches one synthetic name that was not in the original mask set.*

## Keeping context with labels

A black box is enough when the recipient only needs the PII removed. Sometimes they still need to distinguish two people or two accounts. In those cases I can replace the original value with a label such as `Client-1` or `Account-2`.

![Two synthetic taxpayers replaced with Client-1 and Client-2, and their SSNs replaced with SSN-1 and SSN-2](joe-farmer-labels.png)

*Labels keep the relationships in the document without retaining the original PII.*

The value-to-label mapping can be exported as JSON and used on another PDF. It is based on the value, not its location on a particular page.

## Folders of PDFs

Discovery Mode walks every PDF under a folder while I build one shared mask set. Batch Convert takes that JSON set and applies it to the same folder hierarchy.

The optional MCP companion sees opaque IDs such as `document-001` and progress counts. It does not receive the PDFs, filenames, paths, PII, or mask values.

## The export and the tests

Masker rebuilds each exported page from sanitized pixels rather than copying the original PDF structure. Preview may OCR the visible output again, but the masked PII is no longer present in the image.

I vibe-coded this with Codex, but I did not want my tax return anywhere near the test suite. The repo generates fake PDFs, including the Joe Farmer return in these screenshots. After an export, the tests use text extraction and OCR to check that the masked values are actually gone.

Masker is open source. The universal Apple Silicon/Intel app and the optional MCP companion are available from the [latest GitHub release](https://github.com/cpatil/masker/releases/latest).

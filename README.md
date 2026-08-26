# Masker

**Permanent, local PDF redaction for macOS.**

Masker finds repeated personal information, lets you review every proposed mask in a continuous PDF view, and creates sanitized copies without uploading the document or its contents.

![Masker reviewing a generated Joe Farmer tax return](docs/joe-farmer-overview.png)

*The screenshots use a generated Joe Farmer tax return, not a real financial document.*

## Why

Preview's redaction tool is effective, but selecting every occurrence by hand is tedious. Masker automates the repetitive part while keeping the consequential decision - what gets removed - visible and reversible until export.

Read the short development story: [Nothing Personal: I built a local PDF redactor](docs/why-masker.md).

## Features

- Case-insensitive exact-value matching across one or more PDFs, with outer word boundaries to prevent partial-word masks.
- Longest-match preference for overlapping values, while retaining separate standalone occurrences.
- SSN/ITIN, EIN, email, and US phone detection.
- Compact nine-digit variants when a formatted SSN/ITIN or EIN is found.
- Opt-in first-and-last name variants: `JOE AND MARY FARMER` can also find `Joe Farmer`.
- Opt-in institution account-suffix detection that keeps names such as `MERRILL LYNCH` and right-aligned table amounts visible.
- Line-scoped exceptions that keep the account-suffix detector away from false positives such as `FORM 8879`.
- Search-as-you-type with previous/next navigation and cached on-device OCR; selected masks are omitted from results.
- A local Recent PDFs list that reopens each PDF with its remembered exact values and replacement labels.
- Generic mask-set JSON import and export, including values, labels, label appearance, detector settings, and account-suffix exceptions, with no PDF filename or path.
- Merge-on-import: values are deduplicated case-insensitively, existing labels win, missing labels are filled, and detector settings and exceptions are combined.
- Continuous-scroll review with matches synchronized to the visible page, per-page select-all/select-none controls, and an option to reveal values in the review list.
- Clicking a black or labeled mask selects and scrolls to its review row.
- An optional **Replace with** field for each value. Repeated case-insensitive values share one label, which is burned into the black mask as non-searchable pixels.
- Automatic per-match label orientation. Font, maximum size, text-frame width, and alignment are stored in the portable mask set.
- Permanent export that rasterizes visible content and removes the original text layer, interactive forms and annotations, attachments, scripts, layers, and metadata.
- Discovery Mode recursively walks PDFs under a folder while one shared mask set grows; navigation has no scan or review gate, and the local session can resume after restart.
- Batch Convert applies a mask-set JSON to every PDF under a folder, includes PDFs with no matches, and mirrors its subfolders under `Masked PDFs`.
- An optional MCP companion lets Codex coordinate discovery and batch conversion using opaque IDs and counts without receiving document contents or identifying metadata.

![Searching for a synthetic name that was not in the original mask set](docs/joe-farmer-search.png)

*Incremental search finds a synthetic name that was not in the original mask set.*

![Synthetic taxpayers and SSNs replaced with labels](docs/joe-farmer-labels.png)

*Labels preserve useful relationships without retaining the original PII.*

## Try it

Download the universal macOS build from the [latest release](https://github.com/cpatil/masker/releases/latest), unzip it, and open `Masker.app`. It includes native Apple Silicon and Intel executables.

The downloadable build is ad-hoc signed, not Apple-notarized. On first launch, macOS may require you to right-click the app and choose **Open**. You can also build it directly from source.

### Build from source

Requirements: macOS 13 or newer and Xcode Command Line Tools. Full Xcode and third-party dependencies are not required.

```sh
git clone https://github.com/cpatil/masker.git
cd masker
./build.sh
open Masker.app
```

The build uses SwiftUI, PDFKit, Vision, and Core Graphics from macOS.

Maintainers can create the universal release archive with `./package-release.sh`.

## Discovery, Batch Convert, and MCP

Choose **Discovery Mode...** and select a folder. Masker finds every PDF below it, including nested folders. The session starts with the values, labels, and detector settings already in section 2. Move back and forth freely while growing that shared set, then export it from section 2. Discovery is saved locally and can be resumed after restarting Masker.

Choose **Batch Convert...**, select a folder, and select a mask-set JSON. Masker scans every PDF below the folder and automatically applies every match from that set. Separate outputs are written under `Masked PDFs`, with the original subfolder layout preserved; a PDF with no matches is still copied into the output hierarchy. Source PDFs are never combined or overwritten, and the output folder is excluded from later runs.

Discovery fingerprints each source PDF when the session starts and refuses to open a document that changed afterward. Batch conversion reports processed and failed counts in the app. Review the mask set before running a batch, then inspect the exported pages before sharing them.

The optional MCP companion lets Codex open Masker, advance between opaque discovery IDs, start local scans, begin Batch Convert, and report counts. It has no tool for reading filenames, paths, PDF text, mask values, labels, search results, or screenshots. Masker handles the files and the user handles review.

The native app still has no third-party dependencies. The MCP companion requires Node.js 20 or newer:

```sh
cd mcp
./install.sh --configure-codex
```

Restart Codex after installation. See [mcp/README.md](mcp/README.md) for the tool list and privacy boundary.

## Use it

1. Drop in one or more PDFs. Multiple inputs share one scan and set of values, labels, and detector choices; they are not combined.
2. Enter exact values to mask, one per line, or import a generic mask-set JSON file. Imports merge values, labels, detector settings, and account-suffix exceptions with what is already present.
3. Enable any additional detectors you want.
4. Click **Scan PDFs Locally**.
5. Scroll through the PDF and uncheck anything that should remain visible. **Page: All** and **Page: None** affect only the current page; **Reveal values** controls whether the review rows show matched text.
6. Optionally type a short label such as `Client` or `Account 1` beside a match. Use the adjacent text-style menu to adjust font, maximum size, width, and alignment. Leave the label empty for a plain black mask.
7. Search for possible variants; use **Add & Rescan** when you find another value to remove.
8. Click **Create Sanitized Copy**. With multiple inputs, Masker creates a separate sanitized PDF for each input.

Masker never overwrites an original. The default destination is a `Masked PDFs` folder beside the input, and it can be changed before export. Output names end in `_masked.pdf`; if that name exists, a number is added.

## What "permanent" means

Each exported page is rebuilt from sanitized pixels at 300 DPI using Core Graphics. The original PDF objects are not copied into the output. Masker then reopens the result, verifies that active content is gone, and compares the coarse visual structure of every page with the expected masked source before reporting success.

This intentionally removes the searchable and editable text layer. Replacement labels are rendered into the sanitized page image rather than added as PDF text. Preview and other apps may still use OCR to search text that remains visibly rendered on the page; masked values are removed from those pixels. Rasterization also increases file size compared with object-level redaction.

Mask-set exports contain values, optional replacement labels and appearance, detector settings, and account-suffix exceptions. They do not contain a PDF filename, source path, page numbers, coordinates, or orientation, so the same JSON can be imported anywhere. Import deduplicates values case-insensitively, keeps an existing label, fills an empty label from the imported set, enables detectors selected in either set, and combines exceptions. Label orientation is inferred again from each occurrence. Older per-PDF Masker JSON files remain importable.

## Privacy and limitations

- Processing is local. Image-only pages use Apple's on-device Vision OCR.
- Nothing in the app uploads documents, extracted text, or search terms.
- Preview may make visible pixels searchable with on-device OCR even though the PDF contains no text layer. A masked value itself should not appear in those OCR results.
- Recent file paths, exact mask values, and replacement labels are stored in local macOS preferences and can be cleared from the app.
- Discovery paths, values, labels, detector settings, and source fingerprints are stored only in a local owner-readable session file. The separate MCP status contains only opaque IDs, counts, and workflow state.
- OCR and pattern matching can miss handwriting, unusual typography, separated digits, or poor scans.
- Automatic detectors can produce false positives. Review every selected match and every output page before sharing.
- Masker is a privacy tool, not a guarantee of regulatory compliance.

## Tests

```sh
./test.sh
```

The self-test generates its own searchable, scanned, and rotated PDFs. It covers the `JOE AND MARY FARMER` to `Joe Farmer` name variant, identifier variants, institution suffixes, exceptions, cached OCR search, generic mask-set JSON and detector settings, repeated file loading, merge behavior, pixel-rendered labels, click-to-review selection, resumable recursive discovery, batch conversion, status sanitization, permanent export, and residual-text checks. The MCP tests exercise both supported protocol eras and verify the status privacy boundary. No tax documents or private fixtures are stored in this repository.

An optional local-only corpus test is also available:

```sh
./private-smoke-test.sh /path/to/private/pdf/folder
```

It reports aggregate counts, creates its temporary output outside the repository, and removes that output after validation.

## License

[MIT](LICENSE)

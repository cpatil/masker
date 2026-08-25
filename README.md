# Masker

**Offline, permanent PDF redaction for macOS.**

Masker finds repeated personal information, lets you review every proposed mask in a continuous PDF view, and creates sanitized copies without uploading the document or its contents.

![Masker reviewing a generated test PDF](docs/masker.png)

## Why

Preview's redaction tool is effective, but selecting every occurrence by hand is tedious. Masker automates the repetitive part while keeping the consequential decision - what gets removed - visible and reversible until export.

Read the short development story: [I vibe-coded a PDF redactor because I needed one](docs/why-masker.md).

## Features

- Exact-value matching across one or more PDFs.
- SSN/ITIN, EIN, email, and US phone detection.
- Compact nine-digit variants when a formatted SSN/ITIN or EIN is found.
- Opt-in first-and-last name variants: `JOE AND MARY FARMER` can also find `Joe Farmer`.
- Opt-in institution account-suffix detection that keeps names such as `MERRILL LYNCH` and right-aligned table amounts visible.
- Line-scoped exceptions for false positives such as `FORM 8879`.
- Search-as-you-type with previous/next navigation and cached on-device OCR; selected masks are omitted from results.
- A local Recent PDFs list that restores each PDF's saved mask values and optional replacement labels, and can import or export them as portable JSON.
- Continuous-scroll review with matches synchronized to the visible page; clicking a black mask selects and scrolls to its review row.
- An optional **Replace with** field for each value. Repeated case-insensitive values share one label, which is burned into the black mask as non-searchable pixels.
- Permanent export that removes the original text layer, forms, annotations, attachments, scripts, layers, and metadata.

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

## Use it

1. Drop in one or more PDFs.
2. Enter exact values to mask, one per line.
3. Enable any additional detectors you want.
4. Click **Scan PDFs Locally**.
5. Scroll through the PDF and uncheck anything that should remain visible.
6. Optionally type a short label such as `Client` or `Account 1` beside a match. Leave it empty for a plain black mask.
7. Search for possible variants; use **Add & Rescan** when you find another value to remove.
8. Click **Create Sanitized Copies**.

Masker never overwrites an original. Output names end in `_masked.pdf`; if that name exists, a number is added.

## What "permanent" means

Each exported page is rebuilt from sanitized pixels at 300 DPI using Core Graphics. The original PDF objects are not copied into the output. Masker then reopens the result, verifies that active content is gone, and compares the coarse visual structure of every page with the expected masked source before reporting success.

This intentionally removes the searchable and editable text layer. Replacement labels are rendered into the sanitized page image rather than added as PDF text. Preview and other apps may still use OCR to search text that remains visibly rendered on the page; masked values are removed from those pixels. Rasterization also increases file size compared with object-level redaction.

Mask-value exports use a portable value-to-label mapping. They do not contain page numbers, coordinates, or the source file path, so the same JSON can be imported for another PDF. A value is matched case-insensitively; identical values use the same label everywhere. Version 1 exports from older Masker releases still import as black-only masks.

## Privacy and limitations

- Processing is local. Image-only pages use Apple's on-device Vision OCR.
- Nothing in the app uploads documents, extracted text, or search terms.
- Preview may make visible pixels searchable with on-device OCR even though the PDF contains no text layer. A masked value itself should not appear in those OCR results.
- Recent file paths, exact mask values, and replacement labels are stored in local macOS preferences and can be cleared from the app.
- OCR and pattern matching can miss handwriting, unusual typography, separated digits, or poor scans.
- Automatic detectors can produce false positives. Review every selected match and every output page before sharing.
- Masker is a privacy tool, not a guarantee of regulatory compliance.

## Tests

```sh
./test.sh
```

The self-test generates its own searchable, scanned, and rotated PDFs. It covers the `JOE AND MARY FARMER` to `Joe Farmer` name variant, identifier variants, institution suffixes, exceptions, cached OCR search, portable value/label JSON, pixel-rendered labels, click-to-review selection, permanent export, and residual-text checks. No tax documents or private fixtures are stored in this repository.

An optional local-only corpus test is also available:

```sh
./private-smoke-test.sh /path/to/private/pdf/folder
```

It reports aggregate counts, creates its temporary output outside the repository, and removes that output after validation.

## License

[MIT](LICENSE)

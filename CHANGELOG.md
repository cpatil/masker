# Changelog

## 1.3.3 - 2026-08-24

- Shows the complete PDF filename in a standard macOS tooltip when hovering over a truncated loaded, recent, or active filename.

## 1.3.2 - 2026-08-24

- Prevents false visual-validation failures on dense, small-text tax pages by comparing coarse page structure instead of font-edge pixels.
- Names the specific page and validation reason when an export is rejected.
- Adds a dense three-column tax-style regression page while retaining the deliberately corrupted-page rejection test.

## 1.3.1 - 2026-08-24

- Adds Import Values beside each recent PDF for restoring a Masker JSON export.
- Validates the JSON format and version, removes duplicate values, and warns before importing values exported for a differently named PDF.

## 1.3.0 - 2026-08-24

- Uses Core Graphics directly for page rasterization instead of PDFKit's fragile page-image path.
- Preserves visible source annotations while still removing them from the sanitized PDF structure.
- Compares every sanitized page with the expected masked source image and removes the output if visual validation fails.
- Adds a regression test proving that a half-corrupted PDF is rejected.

## 1.2.2 - 2026-08-24

- Adds an always-visible Recents button and an expandable per-PDF list.
- Places an explicit Export Values action beside each recent PDF; it exports only that PDF's saved mask-value JSON.

## 1.2.1 - 2026-08-24

- Makes the What to Mask panel compact and independently scrollable.
- Adds JSON export for the mask values saved with each recent PDF.
- Rejects pathological mask rectangles and caps raster memory to prevent damaged page rendering.

## 1.2.0 - 2026-08-24

- Adds a persistent Recent PDFs list with quick reopening.
- Saves and restores the exact mask-value list separately for each recent PDF.
- Automatically removes missing files and provides controls to forget one entry or clear all local history.

## 1.1.2 - 2026-08-24

- Detects institution account suffixes before dotted leaders and right-aligned amounts.
- Keeps the institution name and table amount visible while masking only the account identifier.

## 1.1.1 - 2026-08-24

- Incremental search now omits occurrences already covered by selected masks.
- Unchecking a mask immediately makes that occurrence searchable again.
- Institution names remain searchable when only their account suffix is masked.

## 1.1.0 - 2026-08-24

- Added continuous-scroll PDF review with page-synchronized matches.
- Added incremental search with cached on-device OCR and previous/next navigation.
- Added compact SSN/ITIN and EIN variants.
- Added opt-in first-and-last name variants, including the Joe Farmer regression case.
- Added table-aware institution account-suffix masking, including rows labeled `STC`/`LTC`, and line-scoped exceptions.
- Added a visible version badge.
- Exported PDFs are rebuilt from sanitized page pixels and validated before delivery.

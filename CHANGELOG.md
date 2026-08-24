# Changelog

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

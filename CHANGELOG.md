# Changelog

## 1.5.0 - 2026-08-24

- Adds a compact optional **Replace with** field beside each detected value; an empty field keeps the standard black mask.
- Uses one case-insensitive value-to-label mapping across every occurrence, without tying labels to a page or position.
- Burns replacement labels into black masks as white image pixels while keeping sanitized PDFs free of a searchable text layer.
- Upgrades mask-value exports to portable JSON schema v2 and carries replacement mappings across PDFs; schema v1 remains importable.
- Keeps click-to-review behavior for both black-only and labeled masks.

## 1.4.6 - 2026-08-24

- Removes replacement labels and reveal-on-hover, returning preview and export to consistent black masks.
- Clicking a mask now selects, highlights, and scrolls to its corresponding review row.
- Deletes the retired label layout, font, preference, hover tracking, rendering, validation, and test paths.

## 1.4.5 - 2026-08-24

- Replaces stretched gray replacement bars with compact, intrinsic-size labels on an almost-white background.
- Keeps width adjustment useful for narrow source fields without stretching labels across already-wide fields.
- Suppresses duplicate labels based on overlapping source regions, even when their compact label frames do not overlap.

## 1.4.4 - 2026-08-24

- Fixes preview-only mask reveal by tracking pointer movement in the PDF view itself.
- Temporarily removes preview mask annotations while hovered so the underlying page is reliably visible, then restores them when the pointer leaves.
- Cleans up replacement placeholders by suppressing spatially overlapping labels, using the widest safe match rectangle, shortening labels in narrow areas, and drawing a subtle badge around each placeholder.
- Adds persistent live controls for replacement-label font family, point size, and width; the same choices are used in preview and export.

## 1.4.3 - 2026-08-24

- Makes the Recent PDFs import and export actions compact, bordered buttons with icons instead of plain text links.

## 1.4.2 - 2026-08-24

- Fixes Import Values by removing the filename popover's modal presentation conflict and using a non-blocking JSON file chooser.
- Keeps immediate full-filename hover text using an inline tooltip that does not interfere with Recent PDFs actions.
- Adds a file-based JSON import round-trip regression test in addition to the existing decoder test.

## 1.4.1 - 2026-08-24

- Replaces unreliable filename help tags with immediate full-filename hover popovers.
- Adds an optional preview-only mode that reveals a mask under the pointer with a yellow highlight; exports remain permanently sanitized.
- Clarifies that Preview can OCR visible pixels even though Masker removes the PDF text layer, and adds an OCR residual test for labeled exports.

## 1.4.0 - 2026-08-24

- Adds an opt-in export mode that replaces black masks with generic labels such as `<Acct 1>` and `<Name 1>`.
- Reuses labels for repeated values and name variants while assigning distinct labels to different account identifiers, including multiple accounts at one institution.
- Previews each replacement label during review and permanently removes the source pixels before drawing the label.

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

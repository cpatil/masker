# Masker

Masker is a small, offline macOS app for permanently redacting repeated personal information from PDFs.

## Use it

1. Open `Masker.app`.
2. Drop in one or more PDFs.
3. Enter exact values to mask, one per line. Common SSN/ITIN and EIN patterns are enabled by default.
4. Click **Scan PDFs Locally**.
5. Scroll through the complete PDF. The match list follows the visible page; uncheck anything that should remain visible.
6. Use the PDF search box to inspect other strings. **Add & Rescan** adds the search text to the exact-value list.
7. Click **Create Sanitized Copies**.

The app never uploads documents or values. Image-only pages are processed with Apple's on-device Vision OCR.

When a formatted SSN/ITIN or EIN is detected, Masker also searches that document for the same nine digits without separators. Digit boundaries prevent matches inside longer numbers.

**Institution account suffixes** is opt-in. It detects institution-like lines ending in a 3-8 digit identifier and masks only those trailing digits, leaving the institution name visible. It rejects common form, line, page, amount, and tax-year patterns; standalone values from 1900 through 2099 are always treated as years. Every match should still be reviewed.

Use **Never auto-mask lines containing** for line-specific exceptions such as `FORM 8879`. Exceptions suppress only automatic account-suffix matches, so they do not globally exempt the same digits when they appear on a legitimate institution line. Deselecting a review match changes only that occurrence.

**First + last name variants** is opt-in. For an exact value such as `JOE AND MARY FARMER`, it also searches for `JOE FARMER`. This is intentionally not enabled by default because shortened names can produce false positives.

## Safety model

The exported PDF is rebuilt from sanitized page pixels at 300 DPI. This permanently removes the original PDF's text layer, form fields, annotations, attachments, layers, scripts, and metadata. The resulting PDF is intentionally not searchable or editable.

Masker never overwrites an original. Output names end in `_masked.pdf`; if that name exists, a number is added.

Always review every page before sharing. OCR and pattern matching can miss unusual typography, handwriting, separated digits, or low-quality scans.

## Rebuild

Run `./build.sh` on macOS 13 or newer. Xcode Command Line Tools are required; there are no third-party dependencies.

Run `./test.sh` to exercise both searchable-text and image-only OCR redaction, then verify that the sensitive values cannot be recovered from the sanitized output.

For a private local fixture corpus, run `./private-smoke-test.sh /path/to/folder`. It reports only aggregate counts, creates its temporary sanitized copy outside the project, and removes that copy after validation.

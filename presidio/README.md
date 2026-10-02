# Optional Presidio discovery

Masker uses `presidio-analyzer` only to suggest PII candidates. It does not use Presidio to edit PDFs.

The app extracts searchable text with PDFKit or scanned text with Apple's Vision OCR, then sends page text to `presidio_helper.py` over local standard input. The request contains document and page indexes, but no PDF path or filename. The helper returns values, entity types, confidence scores, and occurrence counts. A value enters Masker's portable mask set only after the user selects it. Runtime model loading and public-suffix checks use installed local data; network refreshes are disabled during analysis.

The in-app installer creates a private virtual environment under `~/Library/Application Support/Masker/Presidio`, pins `presidio-analyzer` to 2.2.364, and downloads spaCy's `en_core_web_sm` model. Python 3.10 through 3.14 is required. Existing Masker features do not depend on this environment.

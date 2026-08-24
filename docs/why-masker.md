# I vibe-coded a PDF redactor because Preview made me click too much

This started with a pile of tax PDFs.

I had just learned that Preview on macOS has a proper redaction tool. That was good news. The less good news was that I still had to hunt down and select every occurrence of every name, address, SSN, and account number by hand.

After doing enough of that, I wanted a tool that would handle the boring search work but still make me approve what was going to disappear. That became Masker.

And yes, I vibe-coded it.

I built the app through a long back-and-forth with Codex. I did not arrive with a neat Swift architecture or a detailed spec. I described the problem, tried the result on the documents in front of me, found the places where it was wrong, and asked for the next change.

That loop was fast. It was also a good way to discover how many bad assumptions fit inside the phrase "find some text in a PDF."

For example, the first institution detector selected `FORM 8879` as though it were an account number. Then it missed real account suffixes because the text stored inside the PDF was in a different order from the table on the screen. Later, search appeared to run forever on an 89-page sanitized file. The export had no text layer - intentionally - so every partial search was starting OCR from page one.

Those bugs changed the app. Form numbers and likely years are excluded. Institution matching now looks at page geometry, so the name can stay visible while the account suffix is covered and the amount column is left alone. OCR results are cached, and an old search is cancelled when a new one replaces it.

They also changed how I thought about the project. The generated code was never the part I could trust by itself. The useful part was being able to turn each failure into a repeatable example.

The public test suite makes its own PDFs. It creates searchable text, an image-only page, a rotated page, formatted and unformatted identifiers, institution rows, and false positives that should be ignored. There is even a deliberately plain name test: entering `JOE AND MARY FARMER` can optionally find `Joe Farmer`, but only when that broader matching mode is turned on.

The check I care most about happens after export. Masker rebuilds each page from sanitized pixels, opens the result again, and searches it with both text extraction and OCR. If a selected value is still recoverable, the test fails.

Rasterizing the output is a blunt choice. It makes the file larger and removes searchability. For the documents I was preparing to send to somebody else, I preferred that to a cleverer PDF edit that might leave the original text hiding under a black rectangle.

I am not presenting this as proof that vibe coding makes secure software easy. It does not. Masker can still miss unusual text, and its heuristics can still make a bad suggestion. The UI insists on review for a reason.

But it solved the problem I actually had. It is a small native macOS app, it runs locally, it has no third-party dependencies, and it uploads nothing. I am putting it out there because other people probably have the same tedious stack of PDFs - and because I would like to hear about the next assumption that breaks.

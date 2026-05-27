# gyorsiras-font

Phase 1 of the gyorsiras OCR pipeline: re-orient a PDF that was scanned upside-down so subsequent OCR / processing stages can consume it correctly.

## Setup

Install the required dependencies via [Homebrew Bundle](https://github.com/Homebrew/homebrew-bundle):

```sh
brew bundle
```

This installs `qpdf` (declared in the `Brewfile`).

## Usage

From the repo root, run:

```sh
./scripts/reorient_pdf.sh
```

The script rotates every page by 180° using `qpdf --rotate=180`.

### Paths

- **Input:** `docs/328487128-gyorsiras.pdf`
- **Output:** `docs/gyorsiras-reoriented.pdf`

Both paths are relative to the repo root. The script `cd`s into the repo root before invoking `qpdf`, so it can be called from any working directory.

## Pipeline status

This is **Phase 1** of the gyorsiras OCR pipeline — only the re-orientation step. Subsequent phases (OCR, font extraction, etc.) are not yet implemented.

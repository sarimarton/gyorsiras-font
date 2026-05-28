# gyorsiras-font

Magyar gyorsírás (Gabelsberger-Markovits rendszer) szkennelt oldalaiból OCR-rel és glyph-kivágással
font/karakterkészlet építését célzó projekt. A bemenet a `docs/328487128-gyorsiras.pdf` forrásdokumentum,
a kimenet pedig feldolgozott oldalak, bináris képek, kivágott glyph-ek és OCR szövegek.

## Pipeline overview

A feldolgozási lépések sorrendben:

1. **`docs/328487128-gyorsiras.pdf`** — forrás PDF (a gyorsírás-tankönyv beszkennelt változata)
2. **re-orient** — oldalak forgatása/orientáció helyreállítása
3. **page extract** — egyedi oldalak kinyerése képként a PDF-ből
4. **binarize** — oldalak bináris (fekete/fehér) képpé alakítása
5. **OCR** — szöveges tartalom kinyerése a binarizált oldalakból
6. **glyph crop** — egyedi gyorsírás-jelek (glyph-ek) kivágása

## Directory structure

A `data/` könyvtár a pipeline köztes és végső kimeneteit tartalmazza:

- **`data/pages/`** — a PDF-ből kinyert nyers oldalképek (re-orient és page extract lépések kimenete)
- **`data/binarized/`** — binarizált (fekete/fehér) oldalképek, OCR és glyph crop bemenete
- **`data/glyphs/`** — kivágott egyedi gyorsírás-jelek (glyph crop kimenete)
- **`data/ocr/`** — OCR futtatás kimenete (felismert szöveg, koordináták)

## Setup

```bash
python -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
```

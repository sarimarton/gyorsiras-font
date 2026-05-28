# Magyar gyorsírás-font

OpenType/TrueType font, amely a **magyar gyorsírás jelkészletét** digitálisan reprodukálja. A cél, hogy természetes magyar gépelés közben a megfelelő gyorsírás-ligatúrák automatikusan megjelenjenek, OpenType `liga` / `calt` feature-ökön keresztül.

> Forrásanyag: [`docs/328487128-gyorsiras.pdf`](docs/328487128-gyorsiras.pdf) — egy nyomtatott gyorsírás-könyv szkennelt változata (fejjel lefelé scannelve), amely a szabályokat, ligatúra-definíciókat és betűformákat tartalmazza.

## Projekt fázisok

1. **PDF pipeline** — a forrásanyag gépileg feldolgozható formába hozása (re-orientáció → oldalkinyerés → binarizáció → OCR → glyph-crop). *(folyamatban)*
2. **Font-tervezés alapok** — eszközlánc, koordináta-rendszer, alap betűkészlet vektorizálása.
3. **OpenType feature engineering** — ligatúra-fa, feature-kód (fonttools `feaLib`), HarfBuzz teszt.
4. **Tesztelés, finalizálás** — `fontbakery` validálás, specimen oldal, licenc (OFL).

Részletes roadmap: lásd a kick-off issue-t (#1).

## PDF pipeline áttekintés

```
docs/328487128-gyorsiras.pdf
      │  re-orient (180°)
      ▼
docs/gyorsiras-reoriented.pdf
      │  page extract (≥300 DPI PNG)
      ▼
data/pages/        oldalankénti nagy felbontású képek
      │  binarize (adaptív küszöbölés)
      ▼
data/binarized/    tinta vs. háttér szétválasztva
      │  OCR (Tesseract + hun)
      ▼
data/ocr/          kinyert szöveg
      │  glyph crop
      ▼
data/glyphs/       névvel ellátott ligatúra-jelek (PNG + leíró)
```

## Könyvtárstruktúra

| Könyvtár          | Tartalom                                                        |
|-------------------|-----------------------------------------------------------------|
| `docs/`           | forrás-PDF és származtatott dokumentumok                         |
| `scripts/`        | pipeline-lépések scriptjei                                       |
| `data/pages/`     | oldalankénti nagy felbontású PNG-k                               |
| `data/binarized/` | binarizált (fekete-fehér) oldalképek                            |
| `data/ocr/`       | OCR kimenet (szöveg)                                             |
| `data/glyphs/`    | kivágott, névvel ellátott ligatúra-jelek és leíróik             |

A `data/` nagy fájljai nincsenek verziókövetve (lásd `.gitignore`); csak a struktúra (`.gitkeep`) marad a repóban.

## Setup

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Rendszerszintű függőségek (pl. `qpdf` a re-orientációhoz) a `Brewfile`-ból:

```bash
brew bundle
```

## Pipeline futtatása

**Re-orientáció** (fejjel lefelé scannelt oldalak megfordítása):

```bash
./scripts/reorient_pdf.sh
# bemenet:  docs/328487128-gyorsiras.pdf
# kimenet:  docs/gyorsiras-reoriented.pdf
```

A további lépések (oldalkinyerés, binarizáció, OCR, glyph-crop) külön issue-kban készülnek, és ide kerülnek dokumentálásra, ahogy elérhetővé válnak.

#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

qpdf --rotate=180 docs/328487128-gyorsiras.pdf docs/gyorsiras-reoriented.pdf

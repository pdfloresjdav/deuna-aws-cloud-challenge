#!/usr/bin/env bash
# Render every Mermaid source under docs/diagrams/*.mmd into SVG (vector) and
# PNG (PDF fallback) under docs/diagrams/rendered/, using mermaid-cli driven by
# the system Chrome (no bundled Chromium download). Reproducible and isolated
# from the Terraform tooling.
#
# Prereqs (run once): cd docs/tooling && PUPPETEER_SKIP_DOWNLOAD=true npm install
# Usage (from repo root):  bash docs/tooling/render-diagrams.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL_DIR="${REPO_ROOT}/docs/tooling"
SRC_DIR="${REPO_ROOT}/docs/diagrams"
OUT_DIR="${REPO_ROOT}/docs/diagrams/rendered"
MMDC="${TOOL_DIR}/node_modules/.bin/mmdc"
CFG="${TOOL_DIR}/mermaid-config.json"
PCFG="${TOOL_DIR}/puppeteer-config.json"

# Locate a Chrome/Chromium binary for puppeteer (override with PUPPETEER_EXECUTABLE_PATH).
if [[ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ]]; then
  for cand in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "$(command -v google-chrome || true)" \
    "$(command -v chromium || true)"; do
    if [[ -n "${cand}" && -x "${cand}" ]]; then export PUPPETEER_EXECUTABLE_PATH="${cand}"; break; fi
  done
fi
echo "Using Chrome: ${PUPPETEER_EXECUTABLE_PATH:-<none found>}"

mkdir -p "${OUT_DIR}"
shopt -s nullglob
for src in "${SRC_DIR}"/*.mmd; do
  name="$(basename "${src}" .mmd)"
  echo ">> rendering ${name}"
  "${MMDC}" -i "${src}" -o "${OUT_DIR}/${name}.svg" -c "${CFG}" -p "${PCFG}" -b white
  "${MMDC}" -i "${src}" -o "${OUT_DIR}/${name}.png" -c "${CFG}" -p "${PCFG}" -b white -s 2
done
echo "Done. Rendered assets in docs/diagrams/rendered/"

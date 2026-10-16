#!/usr/bin/env bash
# Fetch dmtools-agents from git MAIN into agents/ for integration tests.
#
# Owner decision 2026-10-15: the agents/ submodule pin is GONE — the
# integration surface (L4 suite, wiring tests) always runs against the
# dmtools-agents MAIN tip, fetched fresh. No lockstep duty, no stale pins.
#
# - AGENTS_FETCH_REF overrides the ref (default: main).
# - AGENTS_FETCH_DIR overrides the target (default: agents/).
# - A pre-existing agents/ tree is REPLACED (always-fresh semantics);
#   pass AGENTS_FETCH_KEEP=1 to reuse an existing checkout.
set -euo pipefail

REF="${AGENTS_FETCH_REF:-main}"
DIR="${AGENTS_FETCH_DIR:-agents}"
URL="${AGENTS_FETCH_URL:-https://github.com/krisztiandeak/dmtools-agents.git}"

if [[ "${AGENTS_FETCH_KEEP:-0}" == "1" && -d "$DIR/.git" ]]; then
  echo "[fetch-agents] $DIR already present (AGENTS_FETCH_KEEP=1) — reusing"
  exit 0
fi

rm -rf "$DIR"
echo "[fetch-agents] cloning $URL @ $REF -> $DIR"
# Keep .git (depth-1 clone): the L4 suite's docs-coverage tests answer
# real `git ls-files` calls from the fetched tree's index.
git clone --depth 1 --branch "$REF" "$URL" "$DIR"
echo "[fetch-agents] $(find "$DIR" -type f | wc -l | tr -d ' ') files at $(git -C "$DIR" rev-parse --short HEAD)"

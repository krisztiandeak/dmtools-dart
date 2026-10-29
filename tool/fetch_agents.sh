#!/usr/bin/env bash
# Fetch dmtools-agents into agents/ for integration tests.
#
# Owner decision 2026-10-15: the agents/ submodule pin is GONE — the
# integration surface (L4 suite, wiring tests) runs against dmtools-agents
# MAIN, fetched fresh. No lockstep duty, no stale pins.
#
# - AGENTS_FETCH_REF overrides the ref (default: main). It may be a branch
#   or a full 40-hex commit SHA. A SHA checks out exactly that commit; this
#   is how a Quality run pins every job to the SHA resolved once at run
#   start (gh-437), so the agents shard partition cannot race with main.
# - AGENTS_FETCH_DIR overrides the target (default: agents/).
# - AGENTS_FETCH_URL overrides the repository URL.
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
if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[fetch-agents] fetching $URL @ commit $REF -> $DIR"
  # Keep .git (depth-1): the L4 suite's docs-coverage tests answer real
  # `git ls-files` calls from the fetched tree's index.
  git init -q "$DIR"
  git -C "$DIR" remote add origin "$URL"
  git -C "$DIR" fetch -q --depth 1 origin "$REF"
  git -C "$DIR" checkout -q FETCH_HEAD
else
  echo "[fetch-agents] cloning $URL @ $REF -> $DIR"
  # Keep .git (depth-1 clone): see note above.
  git clone --depth 1 --branch "$REF" "$URL" "$DIR"
fi
echo "[fetch-agents] $(find "$DIR" -type f | wc -l | tr -d ' ') files at $(git -C "$DIR" rev-parse --short HEAD)"

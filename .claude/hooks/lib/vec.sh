#!/usr/bin/env bash
# vec.sh — thin dispatcher to the `vec` Python package.
#
# Owns the venv lifecycle (create + install on first use or when requirements
# change) so every caller — hooks, agents, the recall plan — invokes the vector
# layer the same way:
#
#   bash .claude/hooks/lib/vec.sh <subcommand> [args...]
#
# Machine output (search/lockcheck JSON) is on stdout; progress is on stderr.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR"
PKG_DIR="$LIB_DIR/vec"
VENV="$PKG_DIR/.venv"
REQ="$PKG_DIR/requirements.txt"
STAMP="$VENV/.req-stamp"

# Resolve repo root for CLAUDE_PROJECT_DIR (config.py also resolves it, but pass
# it explicitly so behaviour is identical whether invoked from a hook or by hand).
KB_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$LIB_DIR/../../.." && pwd)}"

PYTHON_BIN="${VEC_PYTHON:-python3}"

# --- venv bootstrap (idempotent) ---
need_install=0
if [ ! -x "$VENV/bin/python" ]; then
  "$PYTHON_BIN" -m venv "$VENV" >&2 || {
    echo "vec.sh: failed to create venv at $VENV" >&2; exit 1; }
  need_install=1
fi
# Reinstall if requirements changed since last install.
if [ ! -f "$STAMP" ] || ! cmp -s "$REQ" "$STAMP"; then
  need_install=1
fi
if [ "$need_install" -eq 1 ]; then
  "$VENV/bin/python" -m pip install --quiet --upgrade pip >&2 || true
  "$VENV/bin/python" -m pip install --quiet -r "$REQ" >&2 || {
    echo "vec.sh: pip install failed" >&2; exit 1; }
  cp "$REQ" "$STAMP"
fi

exec env PYTHONPATH="$LIB_DIR" CLAUDE_PROJECT_DIR="$KB_ROOT" \
  "$VENV/bin/python" -m vec.cli "$@"

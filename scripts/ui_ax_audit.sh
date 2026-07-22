#!/bin/bash
#
# ui_ax_audit.sh — bounded accessibility-tree audit (Phase 4c).
#
# For each requested UI state, launches Prism with the PRISM_DEBUG_AX_DUMP hook,
# which walks the app's OWN window AX tree, writes a JSON report, and asserts that
# every INTERACTIVE control has a label OR identifier, is >= 20pt, and is on-screen.
# Violations are reported (not fatal — the point is to make regressions visible).
#
# Usage:   scripts/ui_ax_audit.sh [OUTDIR] [state ...]
#   OUTDIR defaults to ./ui-snapshots. Default states: empty studio.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/App/build/Build/Products/Debug/Prism.app/Contents/MacOS/Prism"
OUTDIR="${1:-$REPO/ui-snapshots}"
shift 2>/dev/null || true
STATES=("$@"); [ ${#STATES[@]} -eq 0 ] && STATES=(empty studio)

DELAY=2.5      # let the view tree settle before walking it
AUTOQUIT=12    # fallback quit
MAXWAIT=20

if [ ! -x "$BIN" ]; then echo "ERROR: build missing at $BIN — build the app first." >&2; exit 1; fi
mkdir -p "$OUTDIR"
echo "Prism AX audit → $OUTDIR"; echo

for state in "${STATES[@]}"; do
  json="$OUTDIR/ax_$state.json"
  rm -f "$json"
  log="$(mktemp)"
  seen=YES; [ "$state" = "getting-started" ] && seen=NO
  PRISM_DEBUG_UI_STATE="$state" \
  PRISM_DEBUG_AX_DUMP="$json" \
  PRISM_DEBUG_AX_DELAY="$DELAY" \
  PRISM_DEBUG_AUTO_QUIT_SECONDS="$AUTOQUIT" \
  "$BIN" -prism.hasSeenGettingStarted "$seen" >"$log" 2>&1 &
  apppid=$!
  for _ in $(seq 1 "$MAXWAIT"); do sleep 1; kill -0 "$apppid" 2>/dev/null || break; done
  kill -0 "$apppid" 2>/dev/null && { pkill -x Prism; sleep 1; }

  if [ ! -s "$json" ]; then echo "  [$state] no AX dump produced (see $log)"; continue; fi
  python3 - "$json" "$state" <<'PY'
import json, sys, collections
path, state = sys.argv[1], sys.argv[2]
d = json.load(open(path))
kinds = collections.Counter(v['kind'] for v in d['violations'])
print(f"[{state}] {d['elementCount']} elements, {d['interactiveCount']} interactive, "
      f"{len(d['violations'])} violations {dict(kinds)}")
for v in d['violations']:
    print(f"    {v['kind']:12} {v['role']:14} id={str(v.get('identifier')):32} "
          f"label={str(v.get('label'))[:24]:24} :: {v['detail']}")
PY
done

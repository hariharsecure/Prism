#!/bin/bash
#
# ui_contact_sheet.sh — UI-snapshot regression harness (Phase 4c).
#
# Loops the named UI states baked into the app's PRISM_DEBUG_UI_STATE launch hook,
# launching Prism ONCE per state with the PRISM_DEBUG_SCREENSHOT hook, and produces
# exactly one PNG per state in an output dir — a contact sheet a human/AI can review.
#
# Usage:   scripts/ui_contact_sheet.sh [OUTDIR] [state ...]
#   OUTDIR defaults to ./ui-snapshots. Extra args restrict to those states.
#
# Requires a Debug build of the app (see README) and an ACTIVE/unlocked login
# session (screencapture needs a real display).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/App/build/Build/Products/Debug/Prism.app/Contents/MacOS/Prism"
OUTDIR="${1:-$REPO/ui-snapshots}"
shift 2>/dev/null || true

# The canonical state list — MUST match PrismDebugUIState.allStates in
# App/PrismApp/DebugUIState.swift.
ALL_STATES=(empty one-test-source inspector-camera mixer-expanded soundboard \
  memes destinations-sheet review-finish studio multiview engine-fault getting-started)
STATES=("$@"); [ ${#STATES[@]} -eq 0 ] && STATES=("${ALL_STATES[@]}")

DELAY=3.5          # screenshot fires this many seconds after launch
AUTOQUIT=10        # hard fallback quit (real quit path) if screenshot misses
MAXWAIT=20         # seconds to wait for a launch to exit before force-killing

if [ ! -x "$BIN" ]; then echo "ERROR: build missing at $BIN — build the app first." >&2; exit 1; fi
mkdir -p "$OUTDIR"
echo "Prism UI contact sheet → $OUTDIR"
echo "states: ${STATES[*]}"
echo

pass=0; fail=0
for state in "${STATES[@]}"; do
  work="$(mktemp -d)"
  # Getting Started sheet gate via NSArgumentDomain (per-process, deterministic —
  # the shared on-disk default races across rapid back-to-back launches).
  seen=YES; [ "$state" = "getting-started" ] && seen=NO
  PRISM_DEBUG_UI_STATE="$state" \
  PRISM_DEBUG_SCREENSHOT="$work,$DELAY" \
  PRISM_DEBUG_AUTO_QUIT_SECONDS="$AUTOQUIT" \
  "$BIN" -prism.hasSeenGettingStarted "$seen" >"$work/run.log" 2>&1 &
  apppid=$!
  for _ in $(seq 1 "$MAXWAIT"); do sleep 1; kill -0 "$apppid" 2>/dev/null || break; done
  if kill -0 "$apppid" 2>/dev/null; then echo "  [$state] did not exit — killing"; pkill -x Prism; sleep 1; fi

  # The frontmost captured window (prism_window1.png) is the one we drove into
  # state (for multiview it's the freshly-opened monitor). Keep any extras too.
  shot="$work/prism_window1.png"
  if [ -s "$shot" ]; then
    cp "$shot" "$OUTDIR/$state.png"
    extra=("$work"/prism_window[2-9].png)
    if [ -s "${extra[0]:-/nonexistent}" ]; then cp "${extra[0]}" "$OUTDIR/${state}_2.png"; fi
    bytes=$(stat -f%z "$OUTDIR/$state.png")
    dims=$(sips -g pixelWidth -g pixelHeight "$OUTDIR/$state.png" 2>/dev/null | awk '/pixel/{print $2}' | paste -sd x -)
    echo "  OK  $state.png  ${bytes} bytes  ${dims}"
    pass=$((pass+1))
  else
    echo "  MISS $state — no PNG produced (see $work/run.log)"
    fail=$((fail+1))
  fi
done

echo
echo "captured $pass/${#STATES[@]} states into $OUTDIR ($fail missing)"
[ "$fail" -eq 0 ]

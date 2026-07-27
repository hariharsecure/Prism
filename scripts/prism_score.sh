#!/usr/bin/env bash
# prism_score.sh — a single OBJECTIVE, GRADED acceptance oracle for a Prism change.
#
# Instantiates the ARTS (arXiv 2606.21891) node-evaluation loop for this repo: a change
# is a "node" and this script is the evaluator that returns ONE graded verdict, so
# improvement can be run as a scored search instead of hand-judged one-offs.
#
# The grade is a percentile-style ladder (ARTS reward Eq.1), NOT binary pass/fail:
#   INVALID (-0.5)  build or engine suite fails / produces no valid result   → reject hard
#   REGRESS (-0.2)  valid, but a metric is worse than the recorded baseline
#   HOLD     (0)    valid, metrics within baseline band (no regression, no gain)
#   GAIN    (+1)    valid AND a tracked metric beats baseline (e.g. lower frame-time/RSS)
# A node must clear INVALID before any metric is trusted (null is worse than below-baseline).
#
# Tiers:  --fast  build + engine suite only (the null gate)          [~4 min]
#         --full  + sim harnesses (fidelity) + soak (RSS/perf)       [~8 min]  (needs PRISM_SIM_FEED)
# Env:    PRISM_SIM_FEED   path to a real 1080p H.264+AAC clip; harness lanes SKIP (not fail) if unset.
#         PRISM_BASELINE   json of prior metrics to compare against (default scripts/.prism_baseline.json)
#
# INSPECT discipline (see feedback: a measurement is evidence, not a verdict): on any
# non-GAIN result this prints WHERE it failed so the cause (real regression vs harness/env
# artifact) is diagnosed before the result is believed — never escalate from the number alone.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/PrismStudio"
SDK="${SDKROOT:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
TIER="${1:---fast}"
BASELINE="${PRISM_BASELINE:-$ROOT/scripts/.prism_baseline.json}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
score="HOLD"; reason=""; metrics=""

note(){ printf '  %s\n' "$*"; }
fail_invalid(){ score="INVALID"; reason="$1"; }

echo "== prism_score ($TIER) =="

# ---- Gate 0: null gate — build + engine suite must produce a valid, all-pass result ----
echo "[gate0] engine build + suite"
if ! SDKROOT="$SDK" swift build --package-path "$ENGINE" >"$WORK/build.log" 2>&1; then
  fail_invalid "engine build failed (see build.log tail below)"; tail -5 "$WORK/build.log"
else
  SDKROOT="$SDK" swift test --package-path "$ENGINE" >"$WORK/suite.log" 2>&1
  agg="$(grep -E "Test Suite 'All tests' (passed|failed)" "$WORK/suite.log" | tail -1)"
  exec_line="$(grep -E "Executed [0-9]{2,} tests" "$WORK/suite.log" | tail -1 | sed 's/^[[:space:]]*//')"
  fails="$(grep -cE "' failed \(" "$WORK/suite.log")"
  if [ -z "$agg" ] || echo "$agg" | grep -q failed || [ "${fails:-1}" != "0" ]; then
    fail_invalid "engine suite not clean (${fails:-?} failures) — $exec_line"
    grep -E "' failed \(" "$WORK/suite.log" | head -5
  else
    note "suite: $exec_line"; metrics="suite_ok=1"
  fi
fi

# ---- Full tier: fidelity (sim harnesses) + perf/RSS (soak) ----
if [ "$TIER" = "--full" ] && [ "$score" != "INVALID" ]; then
  if [ -n "${PRISM_SIM_FEED:-}" ] && [ -f "${PRISM_SIM_FEED:-/nonexistent}" ]; then
    echo "[gate1] fidelity — sim harnesses on real video"
    PRISM_SIM_FEED="$PRISM_SIM_FEED" SDKROOT="$SDK" swift test --package-path "$ENGINE" \
      --filter SimulatedDeviceLoopbackTests --filter RealVideoPipelineTests >"$WORK/harness.log" 2>&1
    hfails="$(grep -cE "' failed \(" "$WORK/harness.log")"
    hpass="$(grep -cE "' passed \(" "$WORK/harness.log")"
    if [ "${hfails:-1}" != "0" ]; then fail_invalid "sim harness failed ($hfails) — content did not survive"; grep -E "' failed \(" "$WORK/harness.log" | head
    else note "harnesses: $hpass passed, 0 failed"; metrics="$metrics fidelity_ok=1"; fi
  else
    note "[gate1] SKIP — PRISM_SIM_FEED unset/missing (fidelity lane not run)"
  fi
else
  [ "$TIER" = "--full" ] || note "[gate1/2] skipped (fast tier)"
fi

# ---- Verdict (INSPECT-forward: always say where, never just the grade) ----
echo "== verdict =="
case "$score" in
  INVALID) echo "GRADE: INVALID (-0.5) — $reason";
           echo "INSPECT: a null result. Fix the build/suite before any metric is meaningful.";;
  *)       echo "GRADE: ${score} — metrics: ${metrics:-none}";
           echo "INSPECT: metrics are evidence about THIS run — before trusting a delta, confirm it reproduces (re-run) and isn't an env/harness artifact.";;
esac
[ "$score" = "INVALID" ] && exit 1 || exit 0

#!/bin/bash
# Read the account rate limit state from the Claude Code OAuth usage endpoint.
# Default output is a status block with a policy tier for the model.
# --pct5 prints only the 5-hour utilization as an integer. The wait loop uses it.
set -uo pipefail

ENDPOINT="https://api.anthropic.com/api/oauth/usage"
BETA="oauth-2025-04-20"
MODE="${1:-full}"

command -v jq >/dev/null 2>&1 || { echo "usage-budget: jq not found"; exit 2; }

token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | jq -r '.claudeAiOauth.accessToken // empty')
if [ -z "$token" ]; then
  echo "usage-budget: no OAuth token in the Keychain. Plan limits do not apply to API-key, Bedrock, or Vertex sessions."
  exit 2
fi

body=$(curl -sf --max-time 10 "$ENDPOINT" \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: $BETA" \
  -H "anthropic-version: 2023-06-01" 2>/dev/null)
if [ -z "$body" ]; then
  echo "usage-budget: request to the usage endpoint failed. Treat the budget as unknown."
  exit 3
fi

IFS=$'\t' read -r P5 R5 P7 R7 SPEND < <(printf '%s' "$body" | jq -r '
  def ep: if . == null or . == "" then 0
          else (sub("\\.[0-9]+";"") | sub("\\+00:00";"Z") | fromdateiso8601) end;
  [ (.five_hour.utilization // 0 | floor),
    (.five_hour.resets_at | ep),
    (.seven_day.utilization // 0 | floor),
    (.seven_day.resets_at | ep),
    (.spend.percent // 0 | floor) ] | @tsv' 2>/dev/null)

case "${P5:-}" in ''|*[!0-9]*) echo "usage-budget: unexpected response shape from the endpoint."; exit 3 ;; esac

if [ "$MODE" = "--pct5" ]; then echo "$P5"; exit 0; fi

NOW=$(date +%s)
fmt_reset() {
  local at="$1" m
  [ "$at" -gt 0 ] 2>/dev/null || { echo "reset time unknown"; return; }
  m=$(( (at - NOW) / 60 )); [ "$m" -lt 0 ] && m=0
  if   [ "$m" -ge 1440 ]; then echo "resets in $((m/1440))d $(((m%1440)/60))h"
  elif [ "$m" -ge 60 ];   then echo "resets in $((m/60))h $((m%60))m"
  else                         echo "resets in ${m}m"; fi
}

if   [ "$P5" -ge 95 ]; then TIER=PAUSE
elif [ "$P5" -ge 85 ]; then TIER=MINIMAL
elif [ "$P5" -ge 60 ]; then TIER=CONSERVE
else                        TIER=NORMAL; fi

echo "5h window: ${P5}% used, $(fmt_reset "$R5")   <- governs the tier"
echo "7d window: ${P7}% used, $(fmt_reset "$R7")"
[ "$P7" -ge 90 ] && echo "WARNING: the 7d window is at ${P7}%. It blocks for days, not hours. Apply MINIMAL rules even if the 5h tier is lower."
[ "$SPEND" -ge 100 ] && echo "WARNING: overage credits are at ${SPEND}%. There is no buffer left. Reaching a window limit stops the work."
echo "TIER: $TIER"

case "$TIER" in
  NORMAL)   echo "DIRECTIVE: work normally. No restriction." ;;
  CONSERVE) echo "DIRECTIVE: do not start workflows. Run at most one subagent at a time. Read narrow line ranges, not whole files. Keep answers short." ;;
  MINIMAL)  echo "DIRECTIVE: no subagents, no workflows, no web research. Answer from context that is already loaded. Make the smallest change that satisfies the request. Skip optional verification." ;;
  PAUSE)    echo "DIRECTIVE: stop starting new work. Checkpoint the current step, report what remains, then start the background wait:"
            echo "  Bash(run_in_background=true): ~/.claude/skills/usage-budget/wait-for-reset.sh" ;;
esac

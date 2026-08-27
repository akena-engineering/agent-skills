#!/bin/bash
# Block until the 5-hour rate limit window has room again.
# Start this with the Bash tool and run_in_background=true. The exit wakes the model.
# Arguments: $1 resume threshold in percent (default 60), $2 poll interval in seconds (default 300).
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
THRESHOLD="${1:-60}"
INTERVAL="${2:-300}"
FAILS=0

while true; do
  pct=$("$DIR/check-usage.sh" --pct5 2>/dev/null)
  case "${pct:-}" in
    ''|*[!0-9]*)
      FAILS=$((FAILS + 1))
      if [ "$FAILS" -ge 12 ]; then
        echo "usage-budget: the usage endpoint failed 12 times in a row. Stopping the wait. Check the limit by hand."
        exit 1
      fi
      ;;
    *)
      FAILS=0
      if [ "$pct" -lt "$THRESHOLD" ]; then
        echo "usage-budget: the 5h window is back to ${pct}%. Resume the work from the checkpoint."
        exit 0
      fi
      ;;
  esac
  sleep "$INTERVAL"
done

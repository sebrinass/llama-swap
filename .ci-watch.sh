#!/bin/bash
# Blocking CI monitor using token from env.
set -u
REPO="sebrinass/llama-swap"
RUNID="${TARGET_RUNID:?env TARGET_RUNID required}"
MAX="${MAX_POLLS:-40}"
IV="${INTERVAL:-600}"
for ((i=1;i<=MAX;i++)); do
  echo "[$(date '+%F %T')] poll $i/$MAX"
  st=$(GH_TOKEN="$GITHUB_TOKEN" curl -s -m 30 -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs/$RUNID" \
      | python3 -c 'import sys,json
d=json.load(sys.stdin)
print(d.get("status"), d.get("conclusion"))' 2>/dev/null)
  echo "run: $st"
  if [[ "$st" == completed* ]]; then
    echo "TERMINAL: $st"; exit 0
  fi
  echo "[$(date '+%F %T')] sleeping ${IV}s"
  sleep "$IV"
done
echo "TIMEOUT after $MAX polls"; exit 2
#!/bin/bash
# CI watcher (authenticated): poll run 33388392863 head=0338ab7 every 30 min.
OWNER="sebrinass"
REPO="llama-swap"
INTERVAL=1800
MAX_ITER=11
RUNID="${TARGET_RUNID:-33388392863}"
API="https://api.github.com/repos/${OWNER}/${REPO}/actions/runs/${RUNID}"
H="Authorization: Bearer ${GH_TOKEN}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

for ((i=1; i<=MAX_ITER; i++)); do
    log "poll $i/$MAX_ITER"
    curl -s -m 60 -H "$H" "$API" -o /tmp/run.json
    st=$(python3 -c 'import json;d=json.load(open("/tmp/run.json"));print(d.get("status"),d.get("conclusion"))' 2>/dev/null)
    log "run status: $st"
    if [ -z "$st" ]; then
        log "no data retry in 600s"
        sleep 600; i=$((i-1)); continue
    fi
    curl -s -m 60 -H "$H" "$API/jobs" -o /tmp/jobs.json
    echo "jobs:"
    python3 -c 'import json;d=json.load(open("/tmp/jobs.json"));[print("   ",j["name"],j["status"],j.get("conclusion")) for j in d.get("jobs",[])]'
    state=$(echo "$st" | cut -d' ' -f1)
    if [ "$state" = "completed" ]; then
        concl=$(echo "$st" | cut -d' ' -f2)
        log "BUILD FINISHED: conclusion=$concl"
        if [ "$concl" != "success" ]; then
            python3 -c '
import json
d=json.load(open("/tmp/jobs.json"))
for j in d.get("jobs",[]):
    for s in j.get("steps",[]):
        if s.get("conclusion")=="failure":
            print("FAILED STEP:", j["name"], "->", s["name"]); raise SystemExit
'
        fi
        exit 0
    fi
    log "sleep ${INTERVAL}s (not complete)"
    sleep "$INTERVAL"
done
log "iter cap reached"
exit 1
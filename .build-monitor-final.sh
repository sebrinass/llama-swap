#!/bin/bash
# Monitor final unified build
RUN_ID="29411470748"
REPO="sebrinass/llama-swap"
INTERVAL=600  # 10 minutes
LOG_FILE="/workspace/.build-monitor-final.log"

echo "[$(date)] Starting monitor for build #$RUN_ID" | tee -a "$LOG_FILE"

while true; do
    RESP=$(curl -s "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID")
    STATUS=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)
    CONCLUSION=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('conclusion',''))" 2>/dev/null)
    
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$NOW] status=$STATUS conclusion=$CONCLUSION" | tee -a "$LOG_FILE"
    
    if [ "$STATUS" = "completed" ]; then
        if [ "$CONCLUSION" = "success" ]; then
            echo "[$NOW] BUILD SUCCESS!" | tee -a "$LOG_FILE"
            exit 0
        else
            echo "[$NOW] BUILD FAILED: $CONCLUSION" | tee -a "$LOG_FILE"
            exit 1
        fi
    fi
    
    sleep "$INTERVAL"
done
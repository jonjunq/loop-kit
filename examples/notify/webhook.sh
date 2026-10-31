#!/usr/bin/env bash
# NOTIFY_CMD for any HTTP endpoint (Home Assistant, n8n, Zapier, your own server...): POSTs JSON
# {"project": "...", "message": "...", "time": "..."}. In loopkit.env:
#   NOTIFY_CMD="/path/to/loop-kit/examples/notify/webhook.sh"   WEBHOOK_URL=https://...   export WEBHOOK_URL
set -u
: "${WEBHOOK_URL:?}"
curl -s -m 15 -H 'Content-Type: application/json' -d "$(python3 -c 'import json,sys,time
print(json.dumps({"project": sys.argv[1], "message": sys.argv[2], "time": time.strftime("%Y-%m-%dT%H:%M:%S%z")}))' "$(basename "$PWD")" "$1")" "$WEBHOOK_URL" >/dev/null

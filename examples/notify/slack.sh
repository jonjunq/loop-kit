#!/usr/bin/env bash
# NOTIFY_CMD for Slack. Create an app with an Incoming Webhook (api.slack.com/apps) and copy its URL. In loopkit.env:
#   NOTIFY_CMD="/path/to/loop-kit/examples/notify/slack.sh"   SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
#   export SLACK_WEBHOOK_URL
set -u
: "${SLACK_WEBHOOK_URL:?}"
msg="$(basename "$PWD"): $1"
curl -s -m 15 -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$msg")" "$SLACK_WEBHOOK_URL" >/dev/null

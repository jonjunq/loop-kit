#!/usr/bin/env bash
# NOTIFY_CMD for Discord. Channel settings -> Integrations -> Webhooks -> New webhook -> copy URL. In loopkit.env:
#   NOTIFY_CMD="/path/to/loop-kit/examples/notify/discord.sh"   DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
#   export DISCORD_WEBHOOK_URL
set -u
: "${DISCORD_WEBHOOK_URL:?}"
msg="$(basename "$PWD"): ${1:0:1900}"
curl -s -m 15 -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$msg")" "$DISCORD_WEBHOOK_URL" >/dev/null

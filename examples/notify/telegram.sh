#!/usr/bin/env bash
# NOTIFY_CMD for Telegram. Create a bot with @BotFather, send it a message, and get your chat id from
# https://api.telegram.org/bot<TOKEN>/getUpdates. In loopkit.env:
#   NOTIFY_CMD="/path/to/loop-kit/examples/notify/telegram.sh"
#   TELEGRAM_BOT_TOKEN=123456:ABC...   TELEGRAM_CHAT_ID=123456789   export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
set -u
: "${TELEGRAM_BOT_TOKEN:?}" "${TELEGRAM_CHAT_ID:?}"
curl -s -m 15 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
  --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
  --data-urlencode "text=${LOOPKIT_PREFIX:-🤖 $(basename "$PWD")}: ${1:0:3900}" >/dev/null

#!/usr/bin/env bash
# Sends a notification the same way run.sh does (logs/notify.log + NTFY_TOPIC + NOTIFY_CMD from loopkit.env).
# Used by the usage guard. Handy to test your settings:  ./loopkit/notify.sh "hello"
set -uo pipefail
KIT=$(dirname "$(readlink -f "$0")")
cd "$KIT/.." || exit 1
# shellcheck source=lib.sh
source "$KIT/lib.sh"
load_config
notify "$*"

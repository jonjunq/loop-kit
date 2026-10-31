#!/usr/bin/env bash
# Always up-to-date demo of the app, to show the project while the loop keeps working.
# Follows the latest "harness: Fxxx PASS" commit (never half-done code), builds it in a separate clone
# (<project>-demo, next to the repo: inside the repo the loop rebuilds and runs git reset) and restarts the server.
# Data is kept; it is only recreated when the new commit touches the paths in DEMO_RESEED_PATHS.
# The commands come from demo.env (the planner writes it; see prompts/PLAN.md). In tmux:  ./loopkit/demo.sh   (Ctrl+C stops it)
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)   # project root (this file lives in <project>/loopkit)
[[ -f "$SRC/demo.env" ]] || { echo "No demo.env in $SRC (build, start and demo-data commands; see loopkit/templates/demo.env.example)"; exit 1; }
# shellcheck source=/dev/null
# Two passes: the first sets DEMO_PORT, so in the second $PORT is right even if demo.env uses it inside double quotes
set +u; source "$SRC/demo.env"; export PORT="${DEMO_PORT:-${PORT:-3000}}"; source "$SRC/demo.env"; set -u
: "${DEMO_BUILD:?demo.env: DEMO_BUILD is missing}" "${DEMO_START:?demo.env: DEMO_START is missing}"
APP="${DEMO_DIR:-$SRC-demo}" INTERVAL="${INTERVAL:-60}"

[[ -d "$APP/.git" ]] || git clone -q "$SRC" "$APP" || { echo "Cannot clone $SRC into $APP"; exit 1; }
cd "$APP" && mkdir -p .demo
LOG=.demo/update.log pid="" bad=""

say()    { echo "[$(date +%H:%M)] $*"; }
start()  { bash -c "$DEMO_START" >>.demo/server.log 2>&1 & pid=$!; }
stop()   { [[ -n "$pid" ]] && { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }; pid=""; }
reseed() { [[ -n "${DEMO_RESEED:-}" ]] && bash -c "$DEMO_RESEED" >>"$LOG" 2>&1; }
target() { git -C "$SRC" log -E --grep='^harness: F[0-9.]* (PASS|PASA)$' -1 --format=%H; }
feat()   { git -C "$SRC" log -1 --format=%s "$1" | grep -o 'F[0-9.]*' | head -1; }
update() { # $1 = commit; leaves the clone on it and built, or returns 1
  git fetch -q origin && git checkout -q --detach "$1" || { say "Cannot fetch $(feat "$1")"; return 1; }
  if [[ -n "${DEMO_INSTALL:-}" ]] && { [[ -n "${2:-}" ]] || grep -qE "${DEMO_INSTALL_PATHS:-^(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|requirements[^/]*\.txt|poetry\.lock|uv\.lock)$}" <<<"$changed"; }; then
    bash -c "$DEMO_INSTALL" >>"$LOG" 2>&1
  fi
  bash -c "$DEMO_BUILD" >>"$LOG" 2>&1 || { say "The build of $(feat "$1") fails; keeping the previous version (details in $APP/$LOG)"; return 1; }
}
trap 'stop; say "Demo stopped"; exit 0' INT TERM

want=$(target)
[[ -n "$want" ]] || { say "No feature has passed yet: waiting for the first one"; until want=$(target); [[ -n "$want" ]]; do sleep "$INTERVAL"; done; }
if [[ ! -f .demo/ready || "$(git rev-parse HEAD)" != "$want" ]]; then
  say "Preparing the demo with $(feat "$want")…"; changed=""
  update "$want" first || exit 1
  [[ -f .demo/ready ]] || { reseed; touch .demo/ready; }
fi
start; say "Demo on http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT with $(feat HEAD)${DEMO_LOGIN:+ · $DEMO_LOGIN}"

while sleep "$INTERVAL"; do
  if ! kill -0 "$pid" 2>/dev/null; then say "The server died (see $APP/.demo/server.log). Restarting it"; start; fi
  want=$(target) have=$(git rev-parse HEAD)
  [[ -z "$want" || "$want" == "$have" || "$want" == "$bad" ]] && continue
  changed=$(git -C "$SRC" diff --name-only "$have" "$want")
  say "Updating to $(feat "$want")…"
  # On failure, go back to the running version and rebuild it so a restart does not pick up a half-built tree
  update "$want" || { bad=$want; git checkout -q --detach "$have" && bash -c "$DEMO_BUILD" >>"$LOG" 2>&1; continue; }
  stop
  if [[ -n "${DEMO_RESEED_PATHS:-}" ]] && grep -qE "$DEMO_RESEED_PATHS" <<<"$changed"; then
    reseed; say "The demo data changed and was recreated (log in again)"
  fi
  start; say "Ready with $(feat "$want"). Reload the page"
done

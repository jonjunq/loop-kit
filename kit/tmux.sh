#!/usr/bin/env bash
# Creates the project's tmux session if it does not exist: windows "loop" (an idle shell for run.sh), "roadmap",
# "guard" (with AUTO_RESUME=1) and "demo" (only if demo.env exists). It never starts run.sh itself: the guard does,
# whenever there is work. Run it by hand, or at boot with templates/loopkit-tmux.service.
# Usage: ./loopkit/tmux.sh      Settings (environment): TMUX_SESSION (default loop), TMUX_SOCKET (tmux -L name)
set -uo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
S="${TMUX_SESSION:-loop}"
T=(tmux ${TMUX_SOCKET:+-L "$TMUX_SOCKET"})

"${T[@]}" has-session -t "=$S" 2>/dev/null && { echo "tmux session '$S' already exists"; exit 0; }
"${T[@]}" new-session -d -s "$S" -n loop -c "$ROOT"
win() { # $1 = window name, $2 = command typed into its shell (so Ctrl+C leaves you at a prompt)
  "${T[@]}" new-window -d -t "$S" -n "$1" -c "$ROOT"; sleep 1
  "${T[@]}" send-keys -t "$S:$1" -l "$2"; "${T[@]}" send-keys -t "$S:$1" Enter
}
win roadmap "./loopkit/roadmap.sh"
win guard "AUTO_RESUME=1 TMUX_TARGET=$S:loop ./loopkit/guard.sh"
[[ -f "$ROOT/demo.env" ]] && win demo "./loopkit/demo.sh"
echo "tmux session '$S' ready: tmux attach -t $S"

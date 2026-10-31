#!/usr/bin/env bash
# Usage guard: stops the loop before the 5-hour usage window runs out (see roadmap/guard.py).
# AUTO_RESUME=1 relaunches it when the window renews.
exec python3 "$(dirname "$(readlink -f "$0")")/roadmap/guard.py"

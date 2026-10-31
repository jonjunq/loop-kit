#!/usr/bin/env bash
# Roadmap viewer on http://localhost:8090 (ROADMAP_PORT to change it). Ctrl+C to stop.
exec python3 "$(dirname "$(readlink -f "$0")")/roadmap/serve.py"

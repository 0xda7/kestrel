#!/bin/bash
# Wedge-relaunch backstop: when the harness ServerSupervisor starts a restart
# (sentinel file), SIGKILL the port listener so the port frees instantly and
# the codified one-fresh-instance retry can actually fire. Kills ONLY the
# LISTEN-state socket owner on ITS port. Log: watchdog.log in state dir.
PORT="$1"; STATE="$2"
mkdir -p "$STATE"
while true; do
  if [ -f "$STATE/restart-now" ]; then
    sleep 0.5
    PIDS=$(lsof -t -i tcp:"$PORT" -sTCP:LISTEN 2>/dev/null)
    for p in $PIDS; do kill -9 "$p" 2>/dev/null && echo "$(date -u +%FT%TZ) watchdog: SIGKILLed listener pid $p on port $PORT" >> "$STATE/watchdog.log"; done
    for i in $(seq 1 60); do
      [ -z "$(lsof -t -i tcp:"$PORT" -sTCP:LISTEN 2>/dev/null)" ] && break
      sleep 0.5
    done
    echo "$(date -u +%FT%TZ) watchdog: port $PORT confirmed free" >> "$STATE/watchdog.log"
    rm -f "$STATE/restart-now"
  fi
  sleep 0.5
done

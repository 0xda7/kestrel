#!/bin/bash
# v6 (final): explicit args PORT, STATE, RUNROOT. Pre-creates
# <RUNROOT>/{merlin,baseline}/server-relaunch.log so ServerSupervisor.log()
# writes there (its FileHandle(forWritingTo:) requires the file to exist;
# otherwise the line goes to stderr/console). Then tails both logs; the exact
# supervisor line "restart: killing the port listener" fires the watchdog
# sentinel ONCE per restart, before the SIGTERM — so the watchdog's SIGKILL
# frees the port inside the supervisor's 10 s port-free window and the
# codified one-fresh-instance wedge retry can actually launch.
PORT="$1"; STATE="$2"; RUNROOT="$3"
mkdir -p "$STATE" "$RUNROOT/merlin" "$RUNROOT/baseline"
rm -f "$STATE/restart-now"
touch "$RUNROOT/merlin/server-relaunch.log" "$RUNROOT/baseline/server-relaunch.log"
echo "$(date -u +%FT%TZ) watcher: anchored on ${RUNROOT##*/}" >> "$STATE/watchdog.log"
tail -F -n0 "$RUNROOT/merlin/server-relaunch.log" "$RUNROOT/baseline/server-relaunch.log" 2>/dev/null | while read -r line; do
  case "$line" in
    *"restart: killing the port listener"*)
      echo "$(date -u +%FT%TZ) watcher: restart line -> sentinel" >> "$STATE/watchdog.log"
      touch "$STATE/restart-now"
      ;;
  esac
done

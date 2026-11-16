#!/bin/bash
# MISSION MERLIN security wave 2 — LIVE OS-level confinement proof.
#
# Why this shape: the session's file sandbox is itself a seatbelt, and
# seatbelts do not nest — the check binary's in-process probe correctly
# detected that and shipped the screening fallback there (proven: its
# stderr shows `sandbox-exec: sandbox_apply: Operation not permitted`).
# To prove the SEATBELT branch through a launchd-spawned process (no outer
# sandbox), this script runs the EXACT profile MerlinShell.confinementProfile
# generates (byte-identical shape to Sources/Merlin/MerlinShell.swift,
# with a scratch workspace standing in for the task workspace) through the
# same spawn path the tool uses (`/usr/bin/sandbox-exec -p <profile>
# /bin/sh -c <command>`, child in its own process group).
set -u
WS="$(mktemp -d /tmp/merlin-live-proof.XXXXXX)"
mkdir -p "$WS/.merlin-scratch/tmp"
REAL_HOME="$(dscl . -read /Users/admin NFSHomeDirectory | awk '{print $2}')"
PROFILE="(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (subpath \"$WS\"))(allow file-write* (subpath \"$WS/.merlin-scratch/tmp\"))(deny file-read* (subpath \"$REAL_HOME\"))(allow file-read* (subpath \"$WS\"))"
echo "WORKSPACE: $WS"
echo "REAL_HOME: $REAL_HOME"
echo "PROFILE: $PROFILE"
echo "=== probe 0: seatbelt applies on this (un-nested) process ==="
/usr/bin/sandbox-exec -p "$PROFILE" /bin/echo applied-ok; echo "apply_rc=$?"
echo "=== probe 1: INSIDE write must SUCCEED ==="
/usr/bin/sandbox-exec -p "$PROFILE" /bin/sh -c 'echo inside > inside.txt; cat inside.txt; echo rc=$?' 2>&1
echo "=== probe 2: curl egress must FAIL (network denied) ==="
env -i HOME="$WS/.merlin-scratch" TMPDIR="$WS/.merlin-scratch/tmp" PATH="/usr/bin:/bin" \
  /usr/bin/sandbox-exec -p "$PROFILE" /bin/sh -c 'curl -s -m 3 https://example.com -o /dev/null; echo curl_rc=$?' 2>&1
echo "=== probe 3: outside write must FAIL (write confined) ==="
env -i HOME="$WS/.merlin-scratch" TMPDIR="$WS/.merlin-scratch/tmp" PATH="/usr/bin:/bin" \
  /usr/bin/sandbox-exec -p "$PROFILE" /bin/sh -c 'echo escape > /Users/admin/kestrel-escape-proof.txt 2>&1; echo wr_rc=$?' 2>&1
echo "=== probe 4: real HOME read must FAIL (HOME hidden) ==="
env -i HOME="$WS/.merlin-scratch" TMPDIR="$WS/.merlin-scratch/tmp" PATH="/usr/bin:/bin" \
  /usr/bin/sandbox-exec -p "$PROFILE" /bin/sh -c 'cat ~/.zshrc 2>&1 | head -1; echo hr_rc=$?; echo HOME=$HOME' 2>&1
echo "=== probe 5: process-group kill of a backgrounded grandchild ==="
env -i HOME="$WS/.merlin-scratch" TMPDIR="$WS/.merlin-scratch/tmp" PATH="/usr/bin:/bin" \
  /bin/sh -c '
PROFILE="(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (subpath "\""$WS"\""))(deny file-read* (subpath "\""$REAL_HOME"\""))(allow file-read* (subpath "\""$WS"\""))"
START=$(date +%s)
/usr/bin/sandbox-exec -p "$PROFILE" /bin/sh -c "sleep 60 & wait" &
CHILD=$!
sleep 2
# the timeout ladder, from the caller: TERM then KILL the whole group
kill -TERM -$CHILD 2>/dev/null; sleep 1; kill -KILL -$CHILD 2>/dev/null
wait $CHILD 2>/dev/null
END=$(date +%s)
echo "group-kill elapsed: $((END-START))s (must be ~3s, not 60s)"
sleep 1
if pgrep -fl "sleep 60" >/dev/null 2>&1; then echo "SURVIVOR: yes (BAD)"; pgrep -fl "sleep 60"; else echo "SURVIVOR: none (good — grandchild reaped with the group)"; fi'
rm -rf "$WS"
rm -f /Users/admin/kestrel-escape-proof.txt
echo "=== proof complete ==="

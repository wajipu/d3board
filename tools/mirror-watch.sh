#!/bin/sh
# Watch D3-503 mirror sessions; on each death capture why.
# Logs to /tmp/d3mirror-watch.log
LOG=/tmp/d3mirror-watch.log
ADB=/opt/homebrew/share/android-commandlinetools/platform-tools/adb
while true; do
  PID=$(pgrep -f "scrcpy -s 192.168.40.157" | head -1)
  if [ -n "$PID" ]; then
    START=$(date '+%H:%M:%S')
    # wait for it to die (max 10 min)
    n=0
    while kill -0 "$PID" 2>/dev/null && [ $n -lt 600 ]; do sleep 1; n=$((n+1)); done
    if kill -0 "$PID" 2>/dev/null; then continue; fi
    echo "[$(date '+%H:%M:%S')] mirror pid=$PID lived ${n}s (started $START)" >> "$LOG"
    echo "--- device side:" >> "$LOG"
    $ADB -s 192.168.40.157:5555 shell "netstat -tn 2>/dev/null | grep 5555; dumpsys power | grep -m1 'Display Power'; ps -A | grep -c app_process" >> "$LOG" 2>&1
  fi
  sleep 1
done

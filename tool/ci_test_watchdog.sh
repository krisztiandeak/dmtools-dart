#!/usr/bin/env bash
# CI stall watchdog for `dart test` (gh-445).
#
# Why: a test isolate blocked synchronously in native code (Mailbox.take,
# Process.runSync, sleep) never trips dart test's per-test timeout — timers
# cannot fire on a blocked isolate. The compact reporter keeps re-printing
# the LAST event of ANY concurrently running suite, so the line on screen
# is usually NOT the wedged suite. This wrapper names the real culprit.
#
# How: runs dart test with an extra JSON file reporter, watches the log for
# progress, and when nothing new arrives for STALL_MINUTES it writes a
# diagnosis (suites/tests started but never finished, process tree with
# kernel wait channels, native thread stacks via gdb when available, the
# Dart VM-service view of every isolate), then kills the run so the step
# fails in minutes with evidence instead of burning the job timeout.
#
# Usage: tool/ci_test_watchdog.sh <dart test args...>
# Env:   STALL_MINUTES (default 8), WATCHDOG_DIR (default /tmp/test_watchdog)
set -uo pipefail

STALL_MINUTES="${STALL_MINUTES:-8}"
DIR="${WATCHDOG_DIR:-/tmp/test_watchdog}"
mkdir -p "$DIR"
JSON="$DIR/events.json"
LOG="$DIR/test_run.log"
DIAG="$DIR/stall_diagnosis.txt"
SVC="$DIR/vm_service.json"
rm -f "$JSON" "$LOG" "$DIAG" "$SVC"

# The VM service lets the diagnosis ask every isolate for its stack; an
# isolate that cannot answer is blocked in native code — that IS the signal.
# --coverage already enables the service; the flags only pin where it is.
dart --enable-vm-service=0 --disable-service-auth-codes \
  --write-service-info="file://$SVC" \
  test --file-reporter "json:$JSON" "$@" > >(tee "$LOG") 2>&1 &
PID=$!

diagnose() {
  {
    echo "=== STALL: no test progress for ${STALL_MINUTES} min ($(date -u +%FT%TZ)) ==="
    echo
    echo "--- in-flight (started, never finished) per the JSON reporter ---"
    python3 - "$JSON" <<'PY' || echo "(json reporter unreadable)"
import json, sys
suites, tests, done, loaded = {}, {}, set(), set()
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    t = e.get("type")
    if t == "suite":
        suites[e["suite"]["id"]] = e["suite"].get("path")
    elif t == "testStart":
        tests[e["test"]["id"]] = (e["test"]["suiteID"], e["test"]["name"], e["time"])
    elif t == "testDone":
        done.add(e["testID"])
last = max([v[2] for v in tests.values()] or [0])
open_ = [(suites.get(s), n, ms) for i, (s, n, ms) in tests.items() if i not in done]
if not open_:
    print("(none — the wedge is outside a test body: loading/compiling a suite)")
for path, name, ms in sorted(open_, key=lambda x: x[2]):
    print(f"WEDGED? {path} :: {name} (started {ms/1000:.0f}s into the run, "
          f"{(last-ms)/1000:.0f}s before the last event)")
PY
    echo
    echo "--- process tree (state, kernel wait channel, elapsed) ---"
    ps -eo pid,ppid,stat,wchan:32,etime,args --forest 2>/dev/null \
      | grep -E "dart|curl|git|python|sh -c|PID" | grep -v grep | head -80
    echo
    echo "--- Dart VM service: per-isolate state ---"
    if [ -s "$SVC" ]; then
      python3 - "$SVC" <<'PY' || true
import json, sys, urllib.request
base = json.load(open(sys.argv[1]))["uri"].rstrip("/") + "/"
def rpc(method, **params):
    q = "&".join(f"{k}={v}" for k, v in params.items())
    with urllib.request.urlopen(f"{base}{method}?{q}", timeout=5) as r:
        return json.load(r)["result"]
try:
    isolates = rpc("getVM")["isolates"]
except Exception as e:
    print(f"(vm service unreachable: {e})"); sys.exit(0)
for iso in isolates:
    try:
        frames = rpc("getStack", isolateId=iso["id"]).get("frames", [])
        names = [(f.get("function") or {}).get("name", "?") for f in frames[:8]]
        print(f"ok      {iso['name']}: {' <- '.join(names) or '(idle)'}")
    except Exception:
        # No answer in 5s: the isolate's thread is stuck in native code.
        print(f"BLOCKED {iso['name']}: no stack answer — synchronously wedged")
PY
    else
      echo "(no service info file)"
    fi
    echo
    echo "--- native thread stacks (gdb) ---"
    if command -v gdb >/dev/null 2>&1; then
      for p in $(pgrep -f "dart.*test" | head -5); do
        echo "## pid $p"
        timeout 60 sudo -n gdb -p "$p" -batch -ex "thread apply all bt 12" 2>/dev/null \
          | grep -E "^Thread|^#" | head -300
      done
    else
      echo "(gdb not installed)"
    fi
  } > "$DIAG" 2>&1
  cat "$DIAG"
}

last_size=-1
idle=0
while kill -0 "$PID" 2>/dev/null; do
  sleep 30
  size=$(stat -c %s "$JSON" 2>/dev/null || stat -f %z "$JSON" 2>/dev/null || echo 0)
  if [ "$size" != "$last_size" ]; then
    last_size=$size
    idle=0
  else
    idle=$((idle + 30))
  fi
  if [ "$idle" -ge $((STALL_MINUTES * 60)) ]; then
    echo "::error::dart test stalled ${STALL_MINUTES} min — see stall_diagnosis.txt (gh-445)"
    diagnose
    pkill -TERM -P "$PID" 2>/dev/null; kill -TERM "$PID" 2>/dev/null
    sleep 5
    pkill -KILL -f "dart.*test" 2>/dev/null
    wait "$PID" 2>/dev/null
    exit 124
  fi
done
wait "$PID"

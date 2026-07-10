#!/usr/bin/env bash
# set -e intentionally omitted: a single failed kscreen-doctor call on one
# output must not abort the script mid-teardown, since that would leave
# monitors in a mixed disabled/enabled state with no cleanup.
set -uo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="${RUNTIME_DIR}/sunshine-vmon.pid"
SNAPSHOT_FILE="${RUNTIME_DIR}/sunshine-vmon.snapshot"

# Logs go in XDG_STATE_HOME, not XDG_RUNTIME_DIR: the latter is tmpfs and
# gets wiped on logout/reboot, which is exactly when you'd want to inspect
# a crash. pidfile/snapshot above are genuinely ephemeral session state, so
# they stay in RUNTIME_DIR.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sunshine-vmon"
mkdir -p "$STATE_DIR"
LOGFILE="${STATE_DIR}/start.log"

WIDTH="${SUNSHINE_CLIENT_WIDTH:-1920}"
HEIGHT="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS%.*}"
FPS="${FPS:-60}"
FPS_MHZ=$(( FPS * 1000 ))
RES="${WIDTH}x${HEIGHT}"
# Sunshine doesn't expose which client connected to prep-cmd scripts, only
# the resolution it requested, and apps.json has no per-app env override
# (its "env" key is global-only, applies to every app). Per-client DPI is
# passed as a CLI arg from each app's own "do" command instead: one app
# tile per device, e.g. `sunshine-start-vmon.sh 1.5`.
SCALE="${1:-1}"
NAME="sunshine-vmon"
VNAME="Virtual-${NAME}"
# Random per-session password. Still visible to local users via `ps` (inherent
# to krfb-virtualmonitor's CLI), but at least not a static guessable secret.
PASSWORD="$(head -c16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16)"

log() { echo "[sunshine-start-vmon] $(date '+%H:%M:%S') $*" | tee -a "$LOGFILE" >&2; }

# Fresh log per invocation. Sunshine doesn't forward this script's stdout/
# stderr into its own log, so this file is the only way to see what actually
# went wrong when krfb-virtualmonitor fails to come up.
: > "$LOGFILE"

# Guard against double-invocation (e.g. two rapid connect events). Without
# this, a second run fights the first over port 5905 and overwrites the
# pidfile, leaking the first krfb-virtualmonitor process forever.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  log "virtual monitor already running (pid $(cat "$PIDFILE")), reusing"
  exit 0
fi
rm -f "$PIDFILE"

# Snapshot every current output's full state (enabled, position, mode, scale,
# rotation, priority) *before* touching anything, one JSON object per line.
# The virtual display doesn't exist yet at this point, so this is purely the
# physical monitor layout. sunshine-stop-vmon.sh replays this to restore your
# exact arrangement instead of guessing a single hardcoded output name.
kscreen-doctor --json | jq -c '.outputs[]' > "$SNAPSHOT_FILE"

# Launch in its own session (setsid) so the whole process tree can be killed
# reliably later, even if krfb-virtualmonitor is a wrapper around another
# binary and $! only captures the wrapper's PID. Its own stdout/stderr goes
# to LOGFILE so failures (missing binary, port in use, permission errors,
# etc.) are actually visible instead of just "never appeared".
setsid krfb-virtualmonitor --resolution "$RES" --name "$NAME" --password "$PASSWORD" --port 5905 >>"$LOGFILE" 2>&1 &
VMON_PID=$!
echo "$VMON_PID" > "$PIDFILE"

# Poll for KDE to register the new display instead of a fixed sleep.
found=0
for _ in $(seq 1 50); do  # up to ~10s
  if kscreen-doctor -o 2>/dev/null | grep -q "$VNAME"; then
    found=1
    break
  fi
  sleep 0.2
done

if [ "$found" -ne 1 ]; then
  echo "[sunshine-start-vmon] ERROR: virtual display '${VNAME}' never appeared. krfb-virtualmonitor output was:" >&2
  sed 's/^/[sunshine-start-vmon]   /' "$LOGFILE" >&2
  kill -- "-${VMON_PID}" 2>/dev/null || kill "$VMON_PID" 2>/dev/null || true
  rm -f "$PIDFILE" "$SNAPSHOT_FILE"
  exit 1
fi

# Add custom mode support for the correct frame rate
kscreen-doctor "output.${VNAME}.addCustomMode.${WIDTH}.${HEIGHT}.${FPS_MHZ}.full" ||
  log "warning: addCustomMode failed, continuing with default mode"

# Disable every physical output that was in the snapshot. Any single output
# failing to disable no longer aborts the script.
while read -r output; do
  [ -z "$output" ] && continue
  kscreen-doctor "output.${output}.disable" || log "warning: failed to disable ${output}"
  sleep 0.5
done < <(jq -r '.name' "$SNAPSHOT_FILE")

kscreen-doctor \
  "output.${VNAME}.enable" \
  "output.${VNAME}.mode.${RES}@${FPS}" \
  "output.${VNAME}.scale.${SCALE}" \
  "output.${VNAME}.priority.1" ||
  log "warning: failed to fully configure ${VNAME}"

# Tell Sunshine to capture this display
CONF="${HOME}/.config/sunshine/sunshine.conf"
sed -i '/^output_name/d' "$CONF"
echo "output_name = ${VNAME}" >> "$CONF"

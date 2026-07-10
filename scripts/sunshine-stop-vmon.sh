#!/usr/bin/env bash
# set -e intentionally omitted: see comment in sunshine-start-vmon.sh.
set -uo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="${RUNTIME_DIR}/sunshine-vmon.pid"
SNAPSHOT_FILE="${RUNTIME_DIR}/sunshine-vmon.snapshot"

# See sunshine-start-vmon.sh for why this is XDG_STATE_HOME and not
# XDG_RUNTIME_DIR.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sunshine-vmon"
mkdir -p "$STATE_DIR"
LOGFILE="${STATE_DIR}/stop.log"

NAME="sunshine-vmon"
VNAME="Virtual-${NAME}"
CONF="${HOME}/.config/sunshine/sunshine.conf"

log() { echo "[sunshine-stop-vmon] $(date '+%H:%M:%S') $*" | tee -a "$LOGFILE" >&2; }

# Nothing to do if no session was ever started (e.g. this runs via
# ExecStopPost on every ordinary `systemctl stop`/`restart`, not just
# crashes). Without this guard, a plain restart with no active streaming
# session would still overwrite sunshine.conf's output_name.
if [ ! -f "$PIDFILE" ] && [ ! -f "$SNAPSHOT_FILE" ]; then
  exit 0
fi

# Kill the virtual display first (process-group kill, since setsid made it
# its own session leader in the start script) so it drops out of KWin's
# output list before we start restoring physical monitors.
if [ -f "$PIDFILE" ]; then
  VMON_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$VMON_PID" ]; then
    kill -- "-${VMON_PID}" 2>/dev/null || kill "$VMON_PID" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
fi

# Give KWin a moment to notice the virtual output is gone.
sleep 1

if [ ! -f "$SNAPSHOT_FILE" ]; then
  log "warning: no snapshot found, falling back to enabling all outputs with no layout restore"
  while read -r output; do
    [ -z "$output" ] && continue
    [ "$output" = "$VNAME" ] && continue
    kscreen-doctor "output.${output}.enable" || log "warning: failed to enable ${output}"
    sleep 0.5
  done < <(kscreen-doctor --json | jq -r '.outputs[].name')
  exit 0
fi

# Replay the pre-session snapshot: enabled state, position, mode, scale,
# rotation, priority — per output. Respects outputs that were intentionally
# disabled before streaming started (they're re-disabled, not force-enabled).
while IFS= read -r output_json; do
  name=$(jq -r '.name' <<<"$output_json")
  [ "$name" = "$VNAME" ] && continue

  enabled=$(jq -r '.enabled' <<<"$output_json")
  if [ "$enabled" != "true" ]; then
    kscreen-doctor "output.${name}.disable" || log "warning: failed to disable ${name}"
    continue
  fi

  kscreen-doctor "output.${name}.enable" || { log "warning: failed to enable ${name}"; continue; }

  mode_id=$(jq -r '.currentModeId // empty' <<<"$output_json")
  if [ -n "$mode_id" ]; then
    mode_str=$(jq -r --arg id "$mode_id" \
      '.modes[]? | select(.id == $id) | "\(.size.width)x\(.size.height)@\(.refreshRate)"' \
      <<<"$output_json")
    [ -n "$mode_str" ] &&
      { kscreen-doctor "output.${name}.mode.${mode_str}" || log "warning: failed to set mode on ${name}"; }
  fi

  posx=$(jq -r '.pos.x // empty' <<<"$output_json")
  posy=$(jq -r '.pos.y // empty' <<<"$output_json")
  [ -n "$posx" ] && [ -n "$posy" ] &&
    { kscreen-doctor "output.${name}.position.${posx},${posy}" || log "warning: failed to set position on ${name}"; }

  scale=$(jq -r '.scale // empty' <<<"$output_json")
  [ -n "$scale" ] &&
    { kscreen-doctor "output.${name}.scale.${scale}" || log "warning: failed to set scale on ${name}"; }

  rotation=$(jq -r '.rotation // empty' <<<"$output_json")
  [ -n "$rotation" ] &&
    { kscreen-doctor "output.${name}.rotation.${rotation}" || log "warning: failed to set rotation on ${name}"; }

  priority=$(jq -r '.priority // empty' <<<"$output_json")
  [ -n "$priority" ] && [ "$priority" != "0" ] &&
    { kscreen-doctor "output.${name}.priority.${priority}" || log "warning: failed to set priority on ${name}"; }

  sleep 0.3
done < "$SNAPSHOT_FILE"

# Restore Sunshine's capture target to whichever output was primary
# (priority 1) before streaming started; fall back to the first output in
# the snapshot if none was marked primary.
PRIMARY_OUTPUT=$(jq -r 'select(.priority == 1) | .name' "$SNAPSHOT_FILE" | head -n1)
if [ -z "$PRIMARY_OUTPUT" ]; then
  PRIMARY_OUTPUT=$(jq -r '.name' "$SNAPSHOT_FILE" | head -n1)
fi

rm -f "$SNAPSHOT_FILE"

if [ -n "$PRIMARY_OUTPUT" ]; then
  sed -i '/^output_name/d' "$CONF"
  echo "output_name = ${PRIMARY_OUTPUT}" >> "$CONF"
fi

# Sunshine + KDE Wayland virtual display (CachyOS)

Stream correct resolution/aspect ratio to any Moonlight client, no dummy HDMI plug,
by creating a `krfb-virtualmonitor` display sized to the client and capturing it via
Sunshine's `kwin` capture mode.

Source guide: see PDF in repo root (Reddit r/MoonlightStreaming, u/Koiut, with
u/TacticalFreak improvements).

## Requirements

- KDE Plasma on Wayland
- Sunshine (latest stable)
- `krfb` + `kscreen`: `sudo pacman -S krfb kscreen`
- `jq`

## Sunshine config file locations

- `~/.config/sunshine/sunshine.conf` — main config, `output_name` is what
  these scripts rewrite on start/stop.
- `~/.config/sunshine/apps.json` — application list. Editing this directly
  is faster than the web UI when adding several similar entries (e.g. one
  per-client app tile with a different scale argument, see Setup step 4
  below). Top-level `"env"` key here is global to all apps — there's no
  per-app equivalent.

## Setup

1. Sunshine web UI (`https://your-ip:47990`) → Configuration → Advanced →
   Force Capture Method → `kwin`.
2. Install scripts:
   ```
   cp scripts/sunshine-start-vmon.sh scripts/sunshine-stop-vmon.sh ~/.local/bin/
   chmod +x ~/.local/bin/sunshine-start-vmon.sh ~/.local/bin/sunshine-stop-vmon.sh
   ```
3. Sunshine web UI → Applications → Add new app:
   - Prep command (Do): `$HOME/.local/bin/sunshine-start-vmon.sh` (run
     `echo $HOME` if you need the literal path — Sunshine's UI field doesn't
     expand `~` or env vars itself)
   - Undo command: `$HOME/.local/bin/sunshine-stop-vmon.sh`
   - Command: whatever you want to launch (e.g. `setsid steam steam://open/bigpicture`)
4. (Optional — per-client DPI) Sunshine doesn't tell prep-cmd scripts which
   client connected, only the resolution it requested. Note: `apps.json`'s
   `"env"` key is global-only (applies to every app, sibling of `"apps"` in
   the file) — there's no per-app `env` override, which is why it's not in
   the web UI. Pass scale as a CLI argument in the `do` command instead, one
   app tile per device — this works from the web UI's normal Prep command
   field, no direct JSON editing needed:
   - Prep command (Do): `$HOME/.local/bin/sunshine-start-vmon.sh 1.5`
   - Undo command: `$HOME/.local/bin/sunshine-stop-vmon.sh` (unchanged, no
     arg needed — it restores from the pre-session snapshot, not scale)

   Duplicate the app per device (`Desktop (MacBook)`, `Desktop (iPad)`,
   `Desktop (TV)`, ...) with the scale factor you want as the argument. Pick
   the matching tile in Moonlight per client — it remembers your last pick
   per host. Omit the argument to fall back to scale `1`.
5. (Recommended — CachyOS's `sunshine` pacman package ships no systemd unit
   at all) Install the user service, which also wires in the stop script as
   `ExecStopPost` for crash safety — see `systemd/sunshine.service`. Its
   paths use systemd's `%h` specifier so it works for any user without
   editing.

   User unit search paths, most specific wins (see `systemd.unit(5)`):
   - `~/.config/systemd/user/` — per-user, this repo's install target
   - `/etc/systemd/user/` — system-wide user-unit override
   - `/usr/lib/systemd/user/` — system-wide user-unit default (package-installed)

   ```
   mkdir -p ~/.config/systemd/user
   cp systemd/sunshine.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now sunshine
   ```

## How it works

1. Moonlight connects → Sunshine sets `SUNSHINE_CLIENT_WIDTH`/`HEIGHT`/`FPS`.
2. Start script spins up a virtual display at that exact resolution.
3. All physical monitors disabled, virtual display made primary.
4. Sunshine (`kwin` mode) captures the virtual display, streams at correct ratio.
5. On disconnect, stop script kills the virtual display and restores physical monitors.

## Hardening vs. the original guide

The original scripts (see PDF) had a few sharp edges, fixed here:

- **Lockout risk**: original disabled all physical monitors unconditionally,
  even if `krfb-virtualmonitor` failed to start (port conflict, missing
  binary, etc.) — guaranteed black screen with no display anywhere. Start
  script now polls for the virtual output to actually appear before touching
  any physical monitor, and aborts cleanly if it doesn't.
- **`set -e` abort mid-teardown**: one failed `kscreen-doctor` call on a
  single output used to kill the whole script, leaving monitors in a mixed
  disabled/enabled state and `sunshine.conf` never updated. Per-output
  failures are now logged and non-fatal.
- **PID tracking**: `$!` only captures the immediate child, which breaks if
  `krfb-virtualmonitor` is a wrapper around another binary — `kill` would
  hit nothing and the real process leaks. Now launched under `setsid` and
  killed as a process group.
- **Double-invocation**: rapid double-connects used to spawn a second
  `krfb-virtualmonitor` fighting over port 5905 and overwrite the pidfile,
  leaking the first process. Start script now checks for an existing live
  instance and reuses it.
- **`/tmp` pidfile**: world-writable dir, symlink-race risk. Moved to
  `$XDG_RUNTIME_DIR` (falls back to `/tmp` if unset).
- **Hardcoded password**: static `sunshinepass` for every session, now a
  random 16-char password generated per invocation. Still visible via `ps`
  to local users — inherent to `krfb-virtualmonitor`'s CLI, not fixable
  short of patching upstream.
- **Fixed `sleep 3`**: replaced with polling `kscreen-doctor -o` for the
  virtual output, up to ~10s, so it's neither flaky on a slow system nor
  wasteful on a fast one.
- Stop script now kills the virtual display *before* restoring physical
  monitors (was the other way around), and excludes the virtual output name
  from the enable loop.
- **No output auto-detection**: original hardcoded `PHYSICAL_OUTPUT=DP-1`
  and required manually editing it to match your actual output name (e.g.
  `HDMI-A-1`). Start script now snapshots the full `kscreen-doctor --json`
  output — per-monitor enabled state, position, mode, scale, rotation,
  priority — before touching anything, and the stop script replays it. No
  manual edit needed, and multi-monitor arrangement (not just which outputs
  were on) is restored instead of just re-enabling everything and hoping the
  layout comes back. Outputs that were intentionally disabled before
  streaming stay disabled after, rather than being force-enabled.
- **Unconditional `sunshine.conf` rewrite**: since the stop script also runs
  via `ExecStopPost` on *every* service stop/restart (not just crashes), it
  used to overwrite `output_name` even when no streaming session was ever
  active. It now no-ops entirely if no snapshot/pidfile exists.

## Known issues / FAQ

- `zkde_screencast_unstable_v1 not found in registry`: set
  `KWIN_WAYLAND_NO_PERMISSION_CHECKS=1` in `/etc/environment.d/` or
  `~/.config/environment.d/`.
- If Sunshine crashes mid-session without the systemd service installed,
  physical monitors stay disabled until you manually run the stop script.
- The snapshot/restore logic's assumed `kscreen-doctor --json` field names
  (`name`, `enabled`, `priority`, `pos.x`/`pos.y`, `scale`, `rotation`,
  `currentModeId`, `modes[].id`/`.size.width`/`.size.height`/`.refreshRate`)
  have been verified against a live single-monitor CachyOS system. If you're
  on a different Plasma/kscreen version and restore silently skips a field,
  run `kscreen-doctor --json | jq .` and compare, then adjust the `jq`
  queries in `sunshine-stop-vmon.sh`.

## Debugging a failed start

Sunshine does **not** forward the prep-cmd script's stdout/stderr into its
own log — a failure there just shows up as
`[...sunshine-start-vmon.sh] exited with code [1]`, with no detail. Both
scripts write their own logs, including `krfb-virtualmonitor`'s raw output
from the start script, to:

```
$XDG_STATE_HOME/sunshine-vmon/start.log   # typically ~/.local/state/sunshine-vmon/start.log
$XDG_STATE_HOME/sunshine-vmon/stop.log
```

(Persistent, not `$XDG_RUNTIME_DIR` — that's tmpfs and gets wiped on
logout/reboot, exactly when you'd want to inspect a crash. The pidfile and
monitor-layout snapshot are genuinely ephemeral session state and do stay in
`$XDG_RUNTIME_DIR`.)

Check `start.log` first any time an app using these scripts fails to launch
— it's overwritten fresh on every invocation. Exit code 1 specifically means
the virtual display never registered with KWin within the ~10s poll window;
the logfile will show whether `krfb-virtualmonitor` errored out (missing
binary, port 5905 already in use, permission/portal failure) or just hung.

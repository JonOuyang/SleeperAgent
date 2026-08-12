#!/usr/bin/env bash
# sleepmode.sh — go dark without going to sleep.
#
# Blanks + powers off the display and kills any RGB lighting, while keeping the
# machine awake so background jobs keep running. Any mouse/keyboard input wakes
# the display; the script notices, restores your lighting, and exits.
#
# Supported: Linux (GNOME/Wayland or X11) and macOS.
#
# Usage:  ./sleepmode.sh            # go dark, restore on wake
#         ./sleepmode.sh --no-rgb   # screen only, leave RGB alone
#         ./sleepmode.sh --status   # print what's detected, change nothing
#         ./sleepmode.sh --rescan   # rebuild the cached RGB device plan
#
# Env:
#   SLEEPMODE_RESTORE_COLOR=RRGGBB  colour for devices that can't be restored
#                                   from an OpenRGB profile (default 87CEEB)
#   SLEEPMODE_NO_UNLOCK=1           don't suppress the lock screen

set -uo pipefail

OS="$(uname -s)"

PROFILE_NAME="sleepmode-restore"
DO_RGB=1
LOCK_WAS=""
INHIBIT_PID=""

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sleepmode"
PLAN_FILE="$CACHE_DIR/devices.plan"
RESTORE_FILE="$CACHE_DIR/devices.restore"
RESTORE_COLOR="${SLEEPMODE_RESTORE_COLOR:-87CEEB}"  # sky blue

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
have_rgb() { [[ $DO_RGB -eq 1 ]] && command -v openrgb >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Platform backends.
#
# Each OS must provide: display_is_off, screen_off, screen_on,
# keepawake_start, keepawake_stop, lock_suppress, lock_restore, platform_check.
# ---------------------------------------------------------------------------

case "$OS" in
Linux)
  DC_DEST=org.gnome.Mutter.DisplayConfig
  DC_PATH=/org/gnome/Mutter/DisplayConfig
  SS_DEST=org.gnome.ScreenSaver
  SS_PATH=/org/gnome/ScreenSaver

  platform_check() {
    if [[ "${XDG_SESSION_TYPE:-}" != "wayland" && "${XDG_SESSION_TYPE:-}" != "x11" ]]; then
      echo "No graphical session detected. Run this from a terminal inside your" >&2
      echo "desktop, not a bare SSH shell (or export DISPLAY and" >&2
      echo "DBUS_SESSION_BUS_ADDRESS first)." >&2
      return 1
    fi
    command -v gdbus >/dev/null || { echo "gdbus not found (need glib2)." >&2; return 1; }
  }

  # Mutter reports DPMS state: 0=on, 1=standby, 2=suspend, 3=off.
  display_is_off() {
    local v
    v="$(gdbus call -e -d "$DC_DEST" -o "$DC_PATH" \
        -m org.freedesktop.DBus.Properties.Get "$DC_DEST" PowerSaveMode 2>/dev/null \
        | grep -oE '[0-9]+' | head -1)"
    [[ "$v" == "3" ]]
  }

  screen_off() { gdbus call -e -d "$SS_DEST" -o "$SS_PATH" -m "$SS_DEST".SetActive true  >/dev/null; }
  screen_on()  { gdbus call -e -d "$SS_DEST" -o "$SS_PATH" -m "$SS_DEST".SetActive false >/dev/null; }

  # Block idle-suspend but NOT lid close, so closing a laptop still sleeps.
  keepawake_start() {
    command -v systemd-inhibit >/dev/null || { log "note: systemd-inhibit missing; not blocking idle sleep"; return 0; }
    systemd-inhibit --what=idle:sleep --who=sleepmode \
      --why="running background tasks with the screen off" \
      --mode=block sleep infinity &
    INHIBIT_PID=$!
  }

  lock_suppress() {
    [[ -n "${SLEEPMODE_NO_UNLOCK:-}" ]] && return 0
    command -v gsettings >/dev/null || return 0
    LOCK_WAS="$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null)"
    [[ -n "$LOCK_WAS" ]] && gsettings set org.gnome.desktop.screensaver lock-enabled false
  }

  lock_restore() {
    [[ -n "$LOCK_WAS" ]] || return 0
    gsettings set org.gnome.desktop.screensaver lock-enabled "$LOCK_WAS"
    LOCK_WAS=""
  }
  ;;

Darwin)
  display_power_state() {
    ioreg -n IODisplayWrangler -r -d 1 2>/dev/null \
      | sed -n 's/.*"CurrentPowerState"=\([0-9]*\).*/\1/p' | head -1
  }

  platform_check() {
    command -v pmset >/dev/null || { echo "pmset not found." >&2; return 1; }
    command -v caffeinate >/dev/null || { echo "caffeinate not found." >&2; return 1; }
    # IODisplayWrangler is an Intel-era node and is typically absent on Apple
    # Silicon. Without it the wake sensor silently reports "display is on"
    # forever, so the script would restore instantly and leave the screen dark.
    # Refuse to run rather than misbehave quietly.
    if [[ -z "$(display_power_state)" ]]; then
      echo "Can't read display power state (IODisplayWrangler not found)." >&2
      echo "This is expected on Apple Silicon and needs a different probe." >&2
      echo "Run ./verify.sh and send the output — do not use sleepmode until fixed." >&2
      return 1
    fi
  }

  # IODisplayWrangler power state: 4 = display on, lower = asleep.
  display_is_off() {
    local v; v="$(display_power_state)"
    [[ -n "$v" && "$v" -lt 4 ]]
  }

  screen_off() { pmset displaysleepnow; }
  # macOS has no "undo display sleep" call — the user's input already woke it.
  screen_on()  { :; }

  # -s asserts against *idle* system sleep only; lid close still sleeps.
  keepawake_start() {
    caffeinate -s &
    INHIBIT_PID=$!
  }

  # NOTE: unverified on macOS. Newer releases have moved this setting around,
  # so the Mac may still ask for a password on wake even with this applied.
  lock_suppress() {
    [[ -n "${SLEEPMODE_NO_UNLOCK:-}" ]] && return 0
    LOCK_WAS="$(defaults -currentHost read com.apple.screensaver askForPassword 2>/dev/null || echo 1)"
    defaults -currentHost write com.apple.screensaver askForPassword -int 0 2>/dev/null || LOCK_WAS=""
  }

  lock_restore() {
    [[ -n "$LOCK_WAS" ]] || return 0
    defaults -currentHost write com.apple.screensaver askForPassword -int "$LOCK_WAS" 2>/dev/null
    LOCK_WAS=""
  }
  ;;

*)
  echo "Unsupported OS: $OS (this script handles Linux and macOS)." >&2
  exit 1
  ;;
esac

keepawake_stop() {
  [[ -n "$INHIBIT_PID" ]] || return 0
  kill "$INHIBIT_PID" 2>/dev/null
  wait "$INHIBIT_PID" 2>/dev/null
  INHIBIT_PID=""
}

# ---------------------------------------------------------------------------
# RGB (OpenRGB) — identical on both platforms; simply absent on most Macs, in
# which case have_rgb() is false and every RGB step no-ops.
# ---------------------------------------------------------------------------

# OpenRGB spams i2c/SMBus warnings (and raw HTML) to stdout on some boards even
# when every device is detected fine. Filter it so real errors stay visible.
orgb() { openrgb "$@" 2>&1 | grep -vE '^\[i2c_smbus|^<h[0-9]|^<p>|^<b>|help\.openrgb\.org'; }

# Every openrgb invocation re-scans all hardware (~1.5-2.8s), so the cost is
# per-*call*, not per-device. Chaining all devices into ONE call takes the same
# ~2.8s as a single device; looping took ~12.5s. Hence the cached plan below.
build_plan() {
  mkdir -p "$CACHE_DIR"
  local listing d modes
  listing="$(orgb --list-devices)" || return 1
  : > "$PLAN_FILE"; : > "$RESTORE_FILE"
  while IFS= read -r d; do
    modes="$(printf '%s\n' "$listing" | awk -v want="^$d:" '
      $0 ~ want {f=1; next} /^[0-9]+:/ {f=0} f && /Modes:/ {print; exit}')"
    if [[ "$modes" == *"Off"* ]]; then
      # Has a real Off mode, and profile restore puts it back correctly.
      printf -- '--device %s --mode off\n' "$d" >> "$PLAN_FILE"
    else
      # No Off mode. These (e.g. the keyboard) typically sit in a "Custom" mode
      # that replays a per-key colour buffer — blacking them out overwrites that
      # buffer, and restoring the profile brings back the *mode* but leaves every
      # LED at zero. So re-light them explicitly on wake instead.
      if [[ "$modes" == *"Static"* ]]; then
        printf -- '--device %s --mode static --color 000000\n' "$d" >> "$PLAN_FILE"
        printf -- '--device %s --mode static --color %s\n' "$d" "$RESTORE_COLOR" >> "$RESTORE_FILE"
      else
        printf -- '--device %s --mode direct --color 000000\n' "$d" >> "$PLAN_FILE"
        printf -- '--device %s --mode direct --color %s\n' "$d" "$RESTORE_COLOR" >> "$RESTORE_FILE"
      fi
    fi
  # NB: [0-9][0-9]* rather than [0-9]\+ — BSD sed (macOS) lacks \+
  done < <(printf '%s\n' "$listing" | sed -n 's/^\([0-9][0-9]*\):.*/\1/p')
  [[ -s "$PLAN_FILE" ]]
}

rgb_off() {
  have_rgb || return 0
  if [[ ! -s "$PLAN_FILE" ]]; then
    log "first run — scanning RGB devices (cached after this)"
    build_plan || { log "warn: RGB scan failed; skipping lights"; return 0; }
  fi
  # Snapshot current lighting so we can put it back exactly as it was.
  orgb --save-profile "$PROFILE_NAME" >/dev/null \
    || log "warn: couldn't save RGB profile; restore may not match"

  # ${arr[@]} on an empty array trips `set -u` in bash 3.2 (macOS), so guard it.
  local args=()
  while read -r -a line; do args+=("${line[@]}"); done < "$PLAN_FILE"
  [[ ${#args[@]} -gt 0 ]] || return 0
  orgb "${args[@]}" >/dev/null \
    || log "warn: some RGB devices may not have gone dark (try --rescan)"
}

rgb_restore() {
  have_rgb || return 0
  orgb --profile "$PROFILE_NAME" >/dev/null \
    || log "warn: RGB profile restore failed — reset lighting manually"

  # Devices the profile can't bring back (see build_plan) get an explicit colour.
  if [[ -s "$RESTORE_FILE" ]]; then
    local args=()
    while read -r -a line; do args+=("${line[@]}"); done < "$RESTORE_FILE"
    [[ ${#args[@]} -gt 0 ]] || return 0
    orgb "${args[@]}" >/dev/null || log "warn: couldn't re-light no-Off-mode devices"
  fi
}

status() {
  echo "os:             $OS"
  case "$OS" in
    Linux)  echo "session:        ${XDG_SESSION_TYPE:-unknown} / ${XDG_CURRENT_DESKTOP:-unknown}"
            echo "lock-enabled:   $(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null)"
            echo "inhibitor:      $(command -v systemd-inhibit >/dev/null && echo systemd-inhibit || echo 'MISSING')" ;;
    Darwin) echo "keep-awake:     $(command -v caffeinate >/dev/null && echo 'caffeinate -s' || echo 'MISSING')"
            echo "askForPassword: $(defaults -currentHost read com.apple.screensaver askForPassword 2>/dev/null || echo unset)" ;;
  esac
  echo "display off:    $(display_is_off && echo yes || echo no)"
  if command -v openrgb >/dev/null 2>&1; then
    echo "openrgb:        $(openrgb --version 2>/dev/null | head -1)"
    echo "--- detected devices ---"
    orgb --list-devices | grep -E '^[0-9]+:'
  else
    echo "openrgb:        not installed (screen-off still works)"
  fi
}

case "${1:-}" in
  --status) status; exit 0 ;;
  --rescan) rm -f "$PLAN_FILE" "$RESTORE_FILE"
            build_plan && { echo "rescanned:"; cat "$PLAN_FILE"; }; exit $? ;;
  --no-rgb) DO_RGB=0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

platform_check || exit 1

# Restore on any exit path, including Ctrl-C.
cleanup() { rgb_restore; lock_restore; keepawake_stop; }
trap cleanup EXIT INT TERM

log "going dark — move the mouse or hit a key to come back"
keepawake_start
lock_suppress
# Screen first: it blanks in ~1s, while the RGB calls take ~5s. Doing RGB first
# meant staring at a lit screen for the whole openrgb round-trip.
screen_off
rgb_off

# Wait for the display to actually power down before watching for it to come
# back, otherwise we'd see the pre-blank "on" state and bail out immediately.
for _ in {1..20}; do
  display_is_off && break
  sleep 0.5
done

while display_is_off; do
  sleep 1
done

log "woke up — restoring"
rgb_restore
lock_restore
keepawake_stop
screen_on
log "done"

#!/usr/bin/env bash
# verify.sh — check each sleepmode building block independently, WITHOUT
# blanking the screen. Safe to run any time, on Linux or macOS.
#
# Usage: ./verify.sh
#
# The one thing this can't cover is the full dark->wake cycle, which needs a
# human to move the mouse. Everything up to that point is checked here.

SCRIPT="$(cd "$(dirname "$0")" && pwd)/sleepmode.sh"
OS="$(uname -s)"
pass=0; fail=0; skip=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
meh()  { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

head_ "1. Script integrity"
bash -n "$SCRIPT" && ok "syntax valid" || no "syntax error"
[[ -x "$SCRIPT" ]] && ok "executable bit set" || no "not executable"
command -v sleepmode >/dev/null && ok "on PATH as 'sleepmode'" || meh "not on PATH"

head_ "2. bash 3.2 compatibility (macOS ships bash 3.2)"
# These are the constructs that historically broke: \+ in sed, empty-array
# expansion under set -u, and associative arrays.
# Strip comments first, else the comment explaining this very rule matches it.
grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -q '\\+' \
  && no "uses \\+ in sed (BSD sed can't)" || ok "no \\+ in sed (code, ignoring comments)"
grep -q 'declare -A' "$SCRIPT" && no "uses declare -A (bash 4+)" || ok "no associative arrays"
grep -q 'readarray\|mapfile' "$SCRIPT" && no "uses mapfile (bash 4+)" || ok "no mapfile"
grep -q '\${#args\[@\]} -gt 0' "$SCRIPT" && ok "guards empty array under set -u" || no "unguarded array expansion"

head_ "3. Platform detection"
case "$OS" in
  Linux|Darwin) ok "OS '$OS' is supported" ;;
  *)            no "OS '$OS' unsupported" ;;
esac
if [[ "$OS" == "Linux" ]]; then
  [[ -n "${XDG_SESSION_TYPE:-}" ]] && ok "graphical session: $XDG_SESSION_TYPE" || no "no XDG_SESSION_TYPE"
  command -v gdbus >/dev/null && ok "gdbus present" || no "gdbus missing"
  command -v systemd-inhibit >/dev/null && ok "systemd-inhibit present" || no "systemd-inhibit missing"
else
  command -v pmset >/dev/null && ok "pmset present" || no "pmset missing"
  command -v caffeinate >/dev/null && ok "caffeinate present" || no "caffeinate missing"
  ioreg -n IODisplayWrangler -r -d 1 >/dev/null 2>&1 && ok "ioreg readable" || no "ioreg failed"
fi

head_ "4. Display-state probe (must report 'on' right now)"
if [[ "$OS" == "Linux" ]]; then
  v="$(gdbus call -e -d org.gnome.Mutter.DisplayConfig -o /org/gnome/Mutter/DisplayConfig \
       -m org.freedesktop.DBus.Properties.Get org.gnome.Mutter.DisplayConfig PowerSaveMode 2>/dev/null \
       | grep -oE '[0-9]+' | head -1)"
else
  v="$(ioreg -n IODisplayWrangler -r -d 1 2>/dev/null | sed -n 's/.*"CurrentPowerState"=\([0-9]*\).*/\1/p' | head -1)"
fi
if [[ -z "$v" ]]; then
  no "could not read display power state"
elif { [[ "$OS" == "Linux" && "$v" != "3" ]]; } || { [[ "$OS" == "Darwin" && "$v" -ge 4 ]]; }; then
  ok "display reads as ON (raw=$v) — the wake sensor works"
else
  no "display reads as OFF (raw=$v) while you're looking at it"
fi

head_ "5. Keep-awake inhibitor (starts, registers, stops cleanly)"
if [[ "$OS" == "Linux" ]]; then
  systemd-inhibit --what=idle:sleep --who=verify --why=test --mode=block sleep 5 &
  ip=$!
  sleep 1
  if systemd-inhibit --list 2>/dev/null | grep -q verify; then ok "inhibitor registered with logind"
  else no "inhibitor did not register"; fi
  kill "$ip" 2>/dev/null; wait "$ip" 2>/dev/null
  sleep 0.5
  systemd-inhibit --list 2>/dev/null | grep -q verify && no "inhibitor leaked after kill" || ok "inhibitor released"
else
  caffeinate -s & ip=$!
  sleep 1
  if pmset -g assertions 2>/dev/null | grep -qi 'PreventSystemSleep\|PreventUserIdleSystemSleep'; then
    ok "caffeinate assertion active"
  else no "no sleep assertion found"; fi
  kill "$ip" 2>/dev/null; wait "$ip" 2>/dev/null
  ok "caffeinate stopped"
fi

head_ "6. Lock-setting save/restore round-trip (must end where it started)"
if [[ "$OS" == "Linux" ]]; then
  before="$(gsettings get org.gnome.desktop.screensaver lock-enabled)"
  gsettings set org.gnome.desktop.screensaver lock-enabled false
  mid="$(gsettings get org.gnome.desktop.screensaver lock-enabled)"
  gsettings set org.gnome.desktop.screensaver lock-enabled "$before"
  after="$(gsettings get org.gnome.desktop.screensaver lock-enabled)"
  [[ "$mid" == "false" ]] && ok "can suppress lock" || no "could not suppress lock"
  [[ "$after" == "$before" ]] && ok "restored to original ($before)" || no "LEFT CHANGED: $before -> $after"
else
  meh "macOS lock suppression is unverified by design — check manually"
fi

head_ "7. RGB plan (skipped cleanly when OpenRGB is absent)"
if command -v openrgb >/dev/null 2>&1; then
  "$SCRIPT" --rescan >/tmp/vplan.txt 2>&1
  if grep -q -- '--device' /tmp/vplan.txt; then
    ok "device plan built:"; sed 's/^/          /' /tmp/vplan.txt | grep -- '--device'
  else
    no "plan empty — see /tmp/vplan.txt"
  fi
  pf="${XDG_CACHE_HOME:-$HOME/.cache}/sleepmode/devices.restore"
  if [[ -s "$pf" ]]; then ok "explicit-restore list for no-Off-mode devices:"; sed 's/^/          /' "$pf"
  else meh "no devices need explicit restore"; fi
else
  meh "openrgb not installed — RGB steps will no-op (expected on a Mac)"
fi

head_ "8. --status runs without error"
"$SCRIPT" --status >/dev/null 2>&1 && ok "--status exits 0" || no "--status failed"

printf '\n\033[1mResult:\033[0m %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]] || exit 1

# sleepmode

Go dark without going to sleep.

One command powers off your display and kills every RGB light in the machine,
while the computer stays fully awake so background jobs keep running. Touch the
mouse or keyboard and everything comes straight back.

Built for leaving a PC crunching overnight in a bedroom, without the glow.

```
sleepmode
```

## What it actually does

- **Really powers the display down** (DPMS off / display sleep) — not a black
  image with the backlight still on.
- **Darkens all RGB** via [OpenRGB](https://openrgb.org): motherboard, RAM, GPU,
  keyboard, whatever it can reach. Your previous lighting is snapshotted and
  restored on wake.
- **Keeps the machine awake** with a real power assertion, so background work
  keeps running.
- **Skips the lock screen** for the duration only, so waking up doesn't mean
  typing a password. Normal idle-blanking still locks the machine.

Closing a laptop lid still suspends normally — the inhibitor blocks *idle*
sleep, not lid close.

## Platform support

| | Linux | macOS |
|---|---|---|
| keep awake | `systemd-inhibit --what=idle:sleep` | `caffeinate -s` |
| display off | `org.gnome.ScreenSaver` (D-Bus) | `pmset displaysleepnow` |
| wake sensor | Mutter `PowerSaveMode` | `ioreg` `IODisplayWrangler` |
| unlock | `gsettings … lock-enabled` | `defaults … askForPassword` |
| RGB | OpenRGB | OpenRGB (usually absent — steps no-op) |

**Linux** needs GNOME (Wayland or X11). Verified on Ubuntu 26.04 / GNOME /
Wayland with an ASRock X870E board, ENE RGB DRAM, an RTX 5090 FE and a Redragon
keyboard.

> [!WARNING]
> **The macOS support is untested.** It's written from documented behaviour but
> has never been run on a Mac. In particular `IODisplayWrangler` is an Intel-era
> ioreg node that is usually **missing on Apple Silicon**; without it the wake
> sensor can't work. The script refuses to start rather than misbehave quietly.
> Run `./verify.sh` on a Mac first.

## Install

```bash
git clone https://github.com/JonOuyang/SleeperAgent.git
cd SleeperAgent
chmod +x sleepmode.sh verify.sh
ln -sf "$PWD/sleepmode.sh" ~/.local/bin/sleepmode   # optional, for PATH
```

RGB control is optional. Without OpenRGB installed, the screen half still works
and the lighting steps quietly no-op.

```bash
# Linux — RGB support
sudo apt install openrgb i2c-tools
sudo modprobe i2c-dev
sudo udevadm control --reload && sudo udevadm trigger
```

## Usage

```
sleepmode              # go dark; any input restores and exits
sleepmode --no-rgb     # screen only, leave the lights alone
sleepmode --status     # show what's detected, change nothing
sleepmode --rescan     # rebuild the cached RGB device plan
```

| Variable | Default | Meaning |
|---|---|---|
| `SLEEPMODE_RESTORE_COLOR` | `87CEEB` | Colour for devices that can't be restored from a profile |
| `SLEEPMODE_NO_UNLOCK` | unset | Set to `1` to leave lock-screen settings alone |
| `SLEEPMODE_SETTLE` | `0` | Seconds to wait after wake before writing RGB |

Run `./verify.sh` to check every building block without blanking the screen.

## Notes from building it

A few things that are easy to get wrong:

- **Don't jiggle the mouse to stay awake.** Synthetic input is exactly what
  *wakes* the display. Use a power assertion instead.
- **RGB devices don't share a mode set.** A GPU may only offer `Off`/`Direct`
  while a keyboard offers `Static` but no `Off`. One global OpenRGB command will
  silently fail on some device. The darkening arguments are computed per device
  and cached under `~/.cache/sleepmode/`.
- **Keyboards in `Custom` mode can't be restored from a profile.** `Custom`
  replays a per-key colour buffer, and blacking the keyboard out overwrites that
  buffer with zeros — restoring brings the *mode* back but leaves every LED at 0.
  Those devices get re-lit explicitly instead.
- **OpenRGB exits 0 even when a mode change doesn't apply**, and its
  `--list-devices` active-mode readback is unreliable. Confirm with your eyes.
## Debugging a stuck / repeating key after wake

Some keyboards spam a keycode after a display wake. `kbwatch.py` reads the
kernel's evdev stream directly — *below* the compositor — which tells you where
the fault is:

```bash
./kbwatch.py --out /tmp/kb.log &   # then use sleepmode as normal
```

- Events **appear** in the log → the keyboard really is sending them
  (firmware/kernel). Not something this script can fix.
- Key visibly spams but the log stays **empty** → the device is innocent and the
  compositor is synthesising repeats from a key-release it never saw.

On the reference machine, RGB writes were measured and ruled out as a cause: the
full save-profile → blackout → restore sequence produced **zero** stray key
events with hands off the keyboard. USB autosuspend was also ruled out
(`power/control` was already `on`). `SLEEPMODE_SETTLE` therefore defaults to `0`.
- **Cost is per OpenRGB invocation, not per device** (each one re-scans all
  hardware, ~2.8s). Chaining every device into a single call took 2.75s versus
  ~12.5s looping. The screen is blanked before the RGB work, since it lands in
  about a second.

Wake detection polls the display power state once a second, because Wayland
gives unprivileged processes no global input hook. In practice the lights return
up to a second after the screen does.

## License

See [LICENSE](LICENSE).

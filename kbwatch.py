#!/usr/bin/env python3
"""Log raw keyboard input events, to catch keys nobody pressed.

Useful for diagnosing stuck/repeating keys after a display wake. It reads the
kernel's evdev stream directly, *below* the compositor, so it distinguishes:

  * the keyboard genuinely emitting events (hardware/firmware/kernel), from
  * the compositor synthesising repeats off a key-release it never saw.

If a key visibly spams but nothing shows up here, the device is innocent and the
bug is above evdev (GNOME/Wayland).

Usage:
    ./kbwatch.py                 # auto-detect keyboards, log until Ctrl-C
    ./kbwatch.py --seconds 30    # stop after 30s
    ./kbwatch.py --out FILE      # append to FILE instead of stdout
    ./kbwatch.py /dev/input/eventN ...   # explicit devices

Needs read access to /dev/input/event* — normally granted to the logged-in user
via ACL; otherwise add yourself to the "input" group.
"""
import argparse, os, select, struct, sys, time

FMT = 'llHHi'                      # struct input_event on 64-bit
SZ = struct.calcsize(FMT)
EV_KEY = 1
VALUE = {0: 'release', 1: 'press', 2: 'REPEAT'}

# Just enough names to read the log at a glance; anything else prints its code.
NAMES = {
    1: 'ESC', 14: 'BACKSPACE', 15: 'TAB', 28: 'ENTER', 29: 'LCTRL',
    39: 'SEMICOLON ;', 42: 'LSHIFT', 56: 'LALT', 57: 'SPACE', 58: 'CAPSLOCK',
    103: 'UP', 105: 'LEFT', 106: 'RIGHT', 108: 'DOWN', 125: 'SUPER',
}


def find_keyboards():
    found = []
    for entry in sorted(os.listdir('/sys/class/input')):
        if not entry.startswith('event'):
            continue
        try:
            with open(f'/sys/class/input/{entry}/device/name') as fh:
                name = fh.read().strip()
        except OSError:
            continue
        # Match real keyboards plus the extra HID interfaces they expose, which
        # is where stray keycodes tend to surface.
        if any(k in name.lower() for k in ('keyboard', 'sonix', 'evision')):
            found.append((f'/dev/input/{entry}', name))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('devices', nargs='*')
    ap.add_argument('--seconds', type=float, default=None)
    ap.add_argument('--out', default=None)
    args = ap.parse_args()

    if args.devices:
        devices = [(d, '') for d in args.devices]
    else:
        devices = find_keyboards()
        if not devices:
            sys.exit('no keyboard-like input devices found')

    out = open(args.out, 'a', buffering=1) if args.out else sys.stdout

    fds = {}
    for path, name in devices:
        try:
            fds[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = path
            print(f'# watching {path} {name}', file=out)
        except OSError as exc:
            print(f'# cannot open {path}: {exc}', file=out)

    if not fds:
        sys.exit('no readable input devices (check /dev/input permissions)')

    stamp = time.strftime('%H:%M:%S')
    limit = f'{args.seconds}s' if args.seconds else 'until Ctrl-C'
    print(f'# {stamp} capture started ({limit})', file=out)

    start = time.time()
    count = 0
    try:
        while args.seconds is None or time.time() - start < args.seconds:
            ready, _, _ = select.select(list(fds), [], [], 0.2)
            for fd in ready:
                try:
                    data = os.read(fd, SZ * 64)
                except OSError:
                    continue
                for off in range(0, len(data) - SZ + 1, SZ):
                    _, _, etype, code, value = struct.unpack(FMT, data[off:off+SZ])
                    if etype != EV_KEY:
                        continue
                    count += 1
                    print(f'{time.strftime("%H:%M:%S")}  {fds[fd]}  '
                          f'code={code} {NAMES.get(code, "")}  '
                          f'{VALUE.get(value, value)}', file=out)
    except KeyboardInterrupt:
        pass
    finally:
        for fd in fds:
            os.close(fd)
        print(f'# capture ended, {count} key event(s)', file=out)


if __name__ == '__main__':
    main()

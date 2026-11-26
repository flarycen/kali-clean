#!/usr/bin/env python3
"""Dynamic resolution for i3 in VMware (kali-clean).

VMware's "Autofit Guest" sends the window size to open-vm-tools, which hands it
to the vmwgfx kernel driver. The X server then marks that size as the preferred
mode of the virtual output (Virtual-1) and leaves switching to it to the
desktop. GNOME and KDE do that, and so did the old vmware X driver, but Debian
dropped that driver from testing in 2025, so Kali now uses the generic
modesetting driver and i3 never switches: the guest stays at 1280x800.

This watcher does what those desktops do. It waits for RandR change events and,
whenever the preferred mode of a virtual output changes, switches to it with
xrandr and redraws the wallpaper. It only touches outputs that carry the
"hotplug_mode_update" property, which only virtual GPUs expose, so real monitors
are never changed. A resolution you set yourself stays until VMware asks for a
new size. User-level only: no root, no system files.

  vm-autofit.py              watch (started by i3; one instance per display)
  vm-autofit.py --once       switch to the size VMware asks for now, then exit
  vm-autofit.py --status     show what the X server reports
  vm-autofit.py --self-test  check the parser and the decisions, then exit
"""

import ctypes
import fcntl
import os
import re
import select
import subprocess
import sys
import time

VIRTUAL_PROP = 'hotplug_mode_update'
QUIET = 0.25      # a window drag sends a burst of sizes: act once it settles...
MAX_WAIT = 1.0    # ...but no later than this after the first event of a burst

HOME = os.path.expanduser('~')
WALLPAPER = os.path.join(HOME, '.config', 'i3', 'scripts', 'set-wallpaper.sh')
_state = os.environ.get('XDG_STATE_HOME', '')
STATE_DIR = os.path.join(_state if os.path.isabs(_state) else os.path.join(HOME, '.local', 'state'),
                         'kali-clean')
LOG_FILE = os.path.join(STATE_DIR, 'vm-autofit.log')

_OUTPUT = re.compile(r'(\S+) (connected|disconnected|unknown connection)( primary)?'
                     r'(?: (\d+)x(\d+)\+(-?\d+)\+(-?\d+))?')
_PROP = re.compile(r'\t([^\t:][^:]*):(.*)')
_SIZE = re.compile(r'(\d+)x(\d+)')


class Output:
    def __init__(self, name, connected, primary, geometry):
        self.name = name
        self.connected = connected
        self.primary = primary
        self.geometry = geometry    # (width, height, x, y) while enabled, else None
        self.preferred = None       # (width, height) of its first preferred mode
        self.props = {}

    @property
    def virtual(self):
        return VIRTUAL_PROP in self.props


def parse(text):
    """Parse `xrandr --current --prop` output."""
    outputs, out = [], None
    for line in text.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            out = None
            m = _OUTPUT.match(line)
            if m:
                geometry = tuple(int(m.group(i)) for i in range(4, 8)) if m.group(4) else None
                out = Output(m.group(1), m.group(2) == 'connected', bool(m.group(3)), geometry)
                outputs.append(out)
            continue
        if out is None:
            continue
        if line.startswith('\t'):
            m = _PROP.match(line)       # property values; '\t\t' lines are details
            if m:
                out.props[m.group(1)] = m.group(2).strip()
            continue
        fields = line.split()           # mode line: name, then rates marked * current, + preferred
        if out.preferred is None and len(fields) > 1 and '+' in ''.join(fields[1:]):
            m = _SIZE.match(fields[0])
            if m:
                out.preferred = (int(m.group(1)), int(m.group(2)))
    return outputs


def _natural(name):
    return [int(t) if t.isdigit() else t for t in re.split(r'(\d+)', name)]


def positions(active):
    """Where each output goes: VMware's suggested offsets, else left to right."""
    if len(active) == 1:
        return {active[0].name: (0, 0)}
    try:
        pos = {o.name: (int(o.props['suggested X']), int(o.props['suggested Y'])) for o in active}
    except (KeyError, ValueError):
        pos = {}
    if pos and len(set(pos.values())) == len(pos) and min(min(p) for p in pos.values()) >= 0:
        return pos
    x, pos = 0, {}
    for o in sorted(active, key=lambda o: _natural(o.name)):
        pos[o.name] = (x, 0)
        x += o.preferred[0]
    return pos


def plan(outputs, seen):
    """Decide what to change. Returns (xrandr arguments or None, memory).

    `seen` maps each virtual output to the preferred size already handled, so a
    size picked by hand is kept until VMware asks for a different one."""
    virtual = [o for o in outputs if o.virtual]
    active = sorted((o for o in virtual if o.connected and o.preferred), key=lambda o: _natural(o.name))
    if not active:
        return None, seen
    wanted = {o.name: o.preferred for o in active}
    if wanted == seen:
        return None, seen
    pos = positions(active)
    args, change = [], False
    for o in active:
        x, y = pos[o.name]
        if o.geometry != (o.preferred[0], o.preferred[1], x, y):
            change = True
        args += ['--output', o.name, '--auto', '--pos', '%dx%d' % (x, y)]
    for o in virtual:
        if not o.connected and o.geometry:     # a VMware monitor that was removed
            args += ['--output', o.name, '--off']
            change = True
    return (args if change else None), wanted


def log(message):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG_FILE, 'a', encoding='utf-8') as fh:
            fh.write('%s %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), message))
    except OSError:
        pass


def trim_log(limit=65536, keep=200):
    try:
        if os.path.getsize(LOG_FILE) > limit:
            with open(LOG_FILE, encoding='utf-8', errors='replace') as fh:
                lines = fh.readlines()[-keep:]
            with open(LOG_FILE, 'w', encoding='utf-8') as fh:
                fh.writelines(lines)
    except OSError:
        pass


def xrandr(args, timeout=20):
    return subprocess.run(['xrandr'] + args, stdin=subprocess.DEVNULL, capture_output=True,
                          encoding='utf-8', errors='replace', timeout=timeout)


def query(probe=False):
    """Current layout; probe=True also asks the driver for fresh modes."""
    r = xrandr(['--prop'] if probe else ['--current', '--prop'])
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or 'xrandr exited with %d' % r.returncode)
    return parse(r.stdout)


def apply(args):
    err = ''
    for attempt in range(2):
        if attempt:
            time.sleep(0.5)
        try:
            r = xrandr(args)
        except (OSError, subprocess.SubprocessError) as exc:
            err = str(exc)
            continue
        if r.returncode == 0:
            return True
        err = r.stderr.strip() or 'exit code %d' % r.returncode
    log('xrandr %s failed: %s' % (' '.join(args), err))
    return False


def refresh_wallpaper():
    """feh drew the wallpaper for the old size; draw it again."""
    if not os.path.isfile(WALLPAPER):
        return
    try:
        subprocess.run(['bash', WALLPAPER], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.SubprocessError):
        pass


def step(seen, probe=False):
    try:
        outputs = query(probe)
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        log('cannot read the display layout: %s' % exc)
        return seen
    args, new_seen = plan(outputs, seen)
    if args and apply(args):
        log('resized: xrandr %s' % ' '.join(args))
        refresh_wallpaper()
    return new_seen


def lock_path():
    tag = re.sub(r'[^A-Za-z0-9_.-]', '_', os.environ.get('DISPLAY', '')) or 'none'
    run_dir = os.environ.get('XDG_RUNTIME_DIR', '')
    if not (os.path.isabs(run_dir) and os.path.isdir(run_dir)):
        run_dir = os.path.join(HOME, '.cache', 'kali-clean')
        os.makedirs(run_dir, exist_ok=True)
    return os.path.join(run_dir, 'kali-clean-vm-autofit-%s.lock' % tag)


def take_lock():
    """One watcher per display; i3 runs this again on every reload."""
    fd = os.open(lock_path(), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def x_events():
    """Subscribe to RandR change events on the root window.

    Returns (fd, drain): drain() empties Xlib's queue and reports whether a
    RandR event arrived. None if libX11/libXrandr or the display are missing."""
    try:
        x11 = ctypes.CDLL('libX11.so.6')
        xrr = ctypes.CDLL('libXrandr.so.2')
    except OSError:
        return None
    vp, ul, ci = ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int
    x11.XOpenDisplay.argtypes, x11.XOpenDisplay.restype = [ctypes.c_char_p], vp
    x11.XDefaultRootWindow.argtypes, x11.XDefaultRootWindow.restype = [vp], ul
    x11.XConnectionNumber.argtypes, x11.XConnectionNumber.restype = [vp], ci
    x11.XPending.argtypes, x11.XPending.restype = [vp], ci
    x11.XNextEvent.argtypes, x11.XNextEvent.restype = [vp, vp], ci
    x11.XFlush.argtypes, x11.XFlush.restype = [vp], ci
    xrr.XRRQueryExtension.argtypes = [vp, ctypes.POINTER(ci), ctypes.POINTER(ci)]
    xrr.XRRQueryExtension.restype = ci
    xrr.XRRSelectInput.argtypes, xrr.XRRSelectInput.restype = [vp, ul, ci], None
    xrr.XRRUpdateConfiguration.argtypes, xrr.XRRUpdateConfiguration.restype = [vp], ci
    io_error_handler = ctypes.CFUNCTYPE(ci, vp)
    x11.XSetIOErrorHandler.argtypes, x11.XSetIOErrorHandler.restype = [io_error_handler], vp
    # The X session ended: leave quietly. Kept referenced for the process lifetime.
    x_events.on_io_error = io_error_handler(lambda _dpy: os._exit(0))
    x11.XSetIOErrorHandler(x_events.on_io_error)

    dpy = x11.XOpenDisplay(None)
    if not dpy:
        return None
    base, error = ci(), ci()
    if not xrr.XRRQueryExtension(dpy, ctypes.byref(base), ctypes.byref(error)):
        return None
    # RRScreenChangeNotify | RRCrtcChangeNotify | RROutputChangeNotify | RROutputPropertyNotify
    xrr.XRRSelectInput(dpy, x11.XDefaultRootWindow(dpy), 0xF)
    x11.XFlush(dpy)
    event = (ctypes.c_long * 24)()      # XEvent is a union padded to 24 longs
    kind_of = ctypes.cast(event, ctypes.POINTER(ci))

    def drain():
        got = False
        while x11.XPending(dpy) > 0:
            x11.XNextEvent(dpy, event)
            kind = kind_of[0] - base.value
            if kind == 0:               # RRScreenChangeNotify
                xrr.XRRUpdateConfiguration(event)
            if kind in (0, 1):          # ... or RRNotify (crtc, output, property)
                got = True
        return got

    return x11.XConnectionNumber(dpy), drain


def watch():
    if not os.environ.get('DISPLAY'):
        print('vm-autofit: DISPLAY is not set', file=sys.stderr)
        return 1
    lock = take_lock()
    if lock is None:
        return 0                        # already running for this display
    try:
        outputs = query()
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        log('cannot read the display layout: %s' % exc)
        return 1
    if not any(o.virtual for o in outputs):
        return 0                        # real hardware, or a driver that resizes by itself
    trim_log()
    log('watching %s' % ', '.join(o.name for o in outputs if o.virtual and o.connected))
    seen = step({}, probe=True)         # the size VMware asked for before i3 started
    events = x_events()
    if events is None:
        log('cannot listen for display changes (libX11/libXrandr); sized once only')
        return 1
    fd, drain = events
    first = due = None
    while True:
        now = time.monotonic()
        if drain():
            if first is None:
                first = now
            due = min(now + QUIET, first + MAX_WAIT)
        if due is not None and now >= due:
            first = due = None
            seen = step(seen)
            continue
        select.select([fd], [], [], None if due is None else due - now)


def once():
    try:
        outputs = query(probe=True)
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print('vm-autofit: cannot read the display layout: %s' % exc, file=sys.stderr)
        return 1
    if not any(o.virtual for o in outputs):
        print('No virtual display output here: nothing to do.')
        return 0
    args, wanted = plan(outputs, {})
    if not args:
        print('Already at the size VMware asks for (%s).' % ', '.join('%dx%d' % s for s in wanted.values()))
        return 0
    if not apply(args):
        print('xrandr failed; see %s' % LOG_FILE, file=sys.stderr)
        return 1
    refresh_wallpaper()
    print('Resized to %s.' % ', '.join('%dx%d' % s for s in wanted.values()))
    return 0


def status():
    try:
        outputs = query(probe=True)
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print('vm-autofit: cannot read the display layout: %s' % exc, file=sys.stderr)
        return 1
    virtual = [o for o in outputs if o.virtual]
    if not virtual:
        print('No virtual display output (no "%s" property): the X driver resizes by itself,\n'
              'or this is not a VM. vm-autofit has nothing to do here.' % VIRTUAL_PROP)
        return 0
    print('%-12s %-13s %-17s %s' % ('output', 'state', 'current', 'VMware asks for'))
    for o in virtual:
        cur = '%dx%d+%d+%d' % o.geometry if o.geometry else 'off'
        want = '%dx%d' % o.preferred if o.preferred else '-'
        print('%-12s %-13s %-17s %s' % (o.name, 'connected' if o.connected else 'disconnected', cur, want))
    fd = take_lock()
    if fd is None:
        print('\nwatcher: running')
    else:
        os.close(fd)
        print('\nwatcher: not running (start it with: i3-msg restart)')
    print('If "VMware asks for" does not change when you resize the window, VMware is not sending\n'
          'sizes: enable View > Autosize > Autofit Guest and check that open-vm-tools is running.')
    return 0


_SAMPLE = (
    'Screen 0: minimum 1 x 1, current 1280 x 800, maximum 16384 x 16384\n'
    'Virtual-1 connected primary 1280x800+0+0 (normal left inverted right x axis y axis) 0mm x 0mm\n'
    '\thotplug_mode_update: 1 \n\t\trange: (0, 1)\n'
    '\tsuggested Y: 0 \n\t\trange: (0, -1)\n'
    '\tsuggested X: 0 \n\t\trange: (0, -1)\n'
    '\tCTM: 0 1 0 0 0 0 0 0 0 1 0 0 0 0 0 0 \n\t\t0 1 \n'
    '   2555x1372     59.97 +\n'
    '   3840x2400     59.97  \n'
    '   1280x800      59.81* \n'
    'Virtual-2 disconnected (normal left inverted right x axis y axis)\n'
    '\thotplug_mode_update: 1 \n\t\trange: (0, 1)\n'
)

_TWO = (
    'Screen 0: minimum 1 x 1, current 1280 x 800, maximum 16384 x 16384\n'
    'Virtual-1 connected primary 1280x800+0+0 (normal left inverted right x axis y axis) 0mm x 0mm\n'
    '\thotplug_mode_update: 1 \n\tsuggested X: 0 \n\tsuggested Y: 0 \n'
    '   2555x1372     59.97 +\n'
    '   1280x800      59.81* \n'
    'Virtual-2 connected (normal left inverted right x axis y axis)\n'
    '\thotplug_mode_update: 1 \n\tsuggested X: 2555 \n\tsuggested Y: 0 \n'
    '   1920x1080     60.00 +\n'
)


def self_test():
    outs = parse(_SAMPLE)
    v1 = outs[0]
    assert [o.name for o in outs] == ['Virtual-1', 'Virtual-2'], outs
    assert v1.connected and v1.primary and v1.virtual and not outs[1].connected
    assert v1.geometry == (1280, 800, 0, 0) and v1.preferred == (2555, 1372), (v1.geometry, v1.preferred)
    assert v1.props['suggested X'] == '0' and outs[1].geometry is None
    # First look: switch to the size VMware asks for.
    args, seen = plan(outs, {})
    assert args == ['--output', 'Virtual-1', '--auto', '--pos', '0x0'], args
    assert seen == {'Virtual-1': (2555, 1372)}, seen
    # Same request again (e.g. after a size picked by hand): leave it alone.
    assert plan(outs, seen) == (None, seen)
    # Already there: nothing to do.
    there = parse(_SAMPLE.replace('59.97 +', '59.97*+').replace('59.81* ', '59.81  ')
                  .replace('1280x800+0+0', '2555x1372+0+0'))
    assert plan(there, {}) == (None, {'Virtual-1': (2555, 1372)})
    # Real monitors are never touched.
    assert plan(parse(_SAMPLE.replace('hotplug_mode_update', 'non-desktop')), {})[0] is None
    # Two VMware monitors: the suggested offsets place them, else left to right.
    two = parse(_TWO)
    args, _ = plan(two, {})
    assert args == ['--output', 'Virtual-1', '--auto', '--pos', '0x0',
                    '--output', 'Virtual-2', '--auto', '--pos', '2555x0'], args
    args, _ = plan(parse(_TWO.replace('suggested X: 2555', 'suggested X: 0')), {})
    assert args[-2:] == ['--pos', '2555x0'], args
    # A removed VMware monitor that is still on gets switched off.
    gone = parse(_SAMPLE.replace('Virtual-2 disconnected (', 'Virtual-2 disconnected 1024x768+2555+0 ('))
    args, _ = plan(gone, {'Virtual-1': (2555, 1372), 'Virtual-2': (1024, 768)})
    assert args[-3:] == ['--output', 'Virtual-2', '--off'], args
    print('vm-autofit self-test: ok')
    return 0


def main(argv):
    if len(argv) == 1:
        return watch()
    cmd = {'--once': once, '--status': status, '--self-test': self_test}.get(argv[1])
    if cmd is None or len(argv) > 2:
        print('usage: vm-autofit.py [--once | --status | --self-test]', file=sys.stderr)
        return 2
    return cmd()


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(130)

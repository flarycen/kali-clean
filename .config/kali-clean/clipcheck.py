#!/usr/bin/env python3
"""kali-clean clipboard check: what would VMware send to the host right now?

It replays VMware Tools' guest->host decision (open-vm-tools dndcp,
CopyPasteUIX11::LocalPrimTimestampCB) on the current X selections. Ask
CLIPBOARD and PRIMARY for TIMESTAMP, where only an INTEGER/TIMESTAMP of format
32 counts. Take CLIPBOARD only if it is strictly newer, and fall back to the
other selection when the chosen one has no text. It also shows the running
tmux's copy-command, the copy tools, the VMware user agent and the last copies
tmux made through clip-in.sh.

  clipcheck.py          check the current selections (copy something in tmux first)
  clipcheck.py --test   first send a test line through tmux's copy-command
"""

import ctypes
import os
import select
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser('~')
_state = os.environ.get('XDG_STATE_HOME', '')
CLIP_LOG = os.path.join(_state if os.path.isabs(_state) else os.path.join(HOME, '.local', 'state'),
                        'kali-clean', 'clip.log')
OURS = 'kali-clean/clip-in.sh'


def run(cmd, data=None, timeout=3):
    try:
        r = subprocess.run(cmd, input=data, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return r if r.returncode == 0 else None


def tmux_copy_command():
    if not shutil.which('tmux'):
        return None
    r = run(['tmux', 'show', '-sv', 'copy-command'])
    return r.stdout.decode(errors='replace').strip().replace('\\$', '$') if r else None


def read_text(selection):
    for cmd in (['xsel', '--output', '--' + selection.lower()],
                ['xclip', '-o', '-selection', selection.lower()]):
        if shutil.which(cmd[0]):
            r = run(cmd)
            return r.stdout.decode(errors='replace') if r else ''
    return ''


class _SelectionEvent(ctypes.Structure):
    _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong), ('send_event', ctypes.c_int),
                ('display', ctypes.c_void_p), ('requestor', ctypes.c_ulong),
                ('selection', ctypes.c_ulong), ('target', ctypes.c_ulong),
                ('property', ctypes.c_ulong), ('time', ctypes.c_ulong)]


class _Event(ctypes.Union):
    _fields_ = [('type', ctypes.c_int), ('xselection', _SelectionEvent), ('pad', ctypes.c_long * 24)]


class X:
    """Just enough Xlib to ask a selection owner for TIMESTAMP."""

    def __init__(self):
        vp, ul, ci = ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int
        x = self.x = ctypes.CDLL('libX11.so.6')
        x.XOpenDisplay.argtypes, x.XOpenDisplay.restype = [ctypes.c_char_p], vp
        x.XDefaultRootWindow.argtypes, x.XDefaultRootWindow.restype = [vp], ul
        x.XCreateSimpleWindow.argtypes = [vp, ul, ci, ci, ctypes.c_uint, ctypes.c_uint,
                                          ctypes.c_uint, ul, ul]
        x.XCreateSimpleWindow.restype = ul
        x.XInternAtom.argtypes, x.XInternAtom.restype = [vp, ctypes.c_char_p, ci], ul
        x.XGetAtomName.argtypes, x.XGetAtomName.restype = [vp, ul], vp
        x.XConvertSelection.argtypes = [vp, ul, ul, ul, ul, ul]
        x.XGetSelectionOwner.argtypes, x.XGetSelectionOwner.restype = [vp, ul], ul
        x.XGetWindowProperty.argtypes = [vp, ul, ul, ctypes.c_long, ctypes.c_long, ci, ul,
                                         ctypes.POINTER(ul), ctypes.POINTER(ci), ctypes.POINTER(ul),
                                         ctypes.POINTER(ul), ctypes.POINTER(vp)]
        x.XPending.argtypes, x.XNextEvent.argtypes = [vp], [vp, vp]
        x.XConnectionNumber.argtypes, x.XFlush.argtypes, x.XFree.argtypes = [vp], [vp], [vp]
        self.dpy = x.XOpenDisplay(None)
        if not self.dpy:
            raise OSError('cannot open the X display (DISPLAY=%s)' % os.environ.get('DISPLAY', ''))
        self.win = x.XCreateSimpleWindow(self.dpy, x.XDefaultRootWindow(self.dpy), 0, 0, 1, 1, 0, 0, 0)
        self.prop = self.atom('KC_CLIPCHECK')

    def atom(self, name):
        return self.x.XInternAtom(self.dpy, name.encode(), 0)

    def atom_name(self, atom):
        p = self.x.XGetAtomName(self.dpy, atom)
        if not p:
            return ''
        name = ctypes.string_at(p).decode(errors='replace')
        self.x.XFree(p)
        return name

    def timestamp(self, selection):
        """(value, note): VMware's reading of the owner's TIMESTAMP (0 = rejected)."""
        x, sel = self.x, self.atom(selection)
        if not x.XGetSelectionOwner(self.dpy, sel):
            return 0, 'no owner'
        x.XConvertSelection(self.dpy, sel, self.atom('TIMESTAMP'), self.prop, self.win, 0)
        x.XFlush(self.dpy)
        event, deadline = _Event(), time.monotonic() + 3
        while True:
            while x.XPending(self.dpy):
                x.XNextEvent(self.dpy, ctypes.byref(event))
                if event.type == 31 and event.xselection.selection == sel:   # SelectionNotify
                    if not event.xselection.property:
                        return 0, 'refused TIMESTAMP'
                    return self._read_stamp()
            left = deadline - time.monotonic()
            if left <= 0:
                return 0, 'no answer within 3 s'
            select.select([x.XConnectionNumber(self.dpy)], [], [], left)

    def _read_stamp(self):
        ul, ci = ctypes.c_ulong, ctypes.c_int
        kind, fmt, items, after, data = ul(), ci(), ul(), ul(), ctypes.c_void_p()
        self.x.XGetWindowProperty(self.dpy, self.win, self.prop, 0, 64, 1, 0, ctypes.byref(kind),
                                  ctypes.byref(fmt), ctypes.byref(items), ctypes.byref(after),
                                  ctypes.byref(data))
        name = self.atom_name(kind.value) if kind.value else 'none'
        try:
            if name in ('INTEGER', 'TIMESTAMP') and fmt.value == 32 and items.value >= 1:
                return ctypes.cast(data, ctypes.POINTER(ul))[0] & 0xFFFFFFFF, 'valid'
            return 0, 'invalid TIMESTAMP (%s, format %d)' % (name, fmt.value)
        finally:
            if data:
                self.x.XFree(data)


def preview(text, width=60):
    text = repr(text)[1:-1]
    return "'%s'" % (text if len(text) <= width else text[:width] + '...')


def main(argv):
    if len(argv) > 2 or (len(argv) == 2 and argv[1] != '--test'):
        print('usage: clipcheck.py [--test]', file=sys.stderr)
        return 2
    hints = []
    copy_cmd = tmux_copy_command()
    if copy_cmd is None:
        tmux_line = 'no tmux server running'
    elif OURS in copy_cmd:
        tmux_line = copy_cmd + '  (ok)'
    else:
        tmux_line = (copy_cmd or '(empty)') + '  (OLD)'
        hints.append('tmux still uses the old copy command: run  tmux source-file ~/.tmux.conf')

    if len(argv) == 2:
        stamp = time.strftime('%H:%M:%S')
        cmd = copy_cmd if copy_cmd else 'sh "$HOME/.config/kali-clean/clip-in.sh"'
        run(['sh', '-c', cmd], ('kali-clean clipboard test %s\n' % stamp).encode(), timeout=10)
        time.sleep(0.5)

    tools = [t for t in ('xsel', 'xclip') if shutil.which(t)]
    if not tools:
        hints.append('no copy tool: sudo apt install xsel xclip')
    agent = run(['pgrep', '-f', 'vmtoolsd -n vmusr']) is not None
    if not agent:
        hints.append('VMware Tools user agent is not running (i3 starts it at login): log out and back in')
    try:
        with open(CLIP_LOG, encoding='utf-8', errors='replace') as fh:
            recent = [line.rstrip('\n') for line in fh.readlines()[-3:]]
    except OSError:
        recent = []
    if copy_cmd and OURS in copy_cmd and not recent:
        hints.append('tmux has not used clip-in.sh yet: copy something in tmux, then run this again')

    print('%-20s %s' % ('tmux copy-command', tmux_line))
    print('%-20s %s' % ('copy tools', ', '.join(tools) or 'none'))
    print('%-20s %s' % ('VMware Tools agent', 'running' if agent else 'NOT running'))
    for i, line in enumerate(recent or ['none yet']):
        print('%-20s %s' % ('recent copies' if i == 0 else '', line))
    try:
        xdisplay = X()
    except OSError as exc:
        print('%-20s %s' % ('X selections', exc))
        return 1
    stamps, texts = {}, {}
    for name in ('CLIPBOARD', 'PRIMARY'):
        stamps[name], note = xdisplay.timestamp(name)
        texts[name] = read_text(name)
        when = 'timestamp %d' % stamps[name] if stamps[name] else note
        print('%-20s %-28s %s' % (name, when, preview(texts[name])))
    order = ('CLIPBOARD', 'PRIMARY') if stamps['CLIPBOARD'] > stamps['PRIMARY'] else ('PRIMARY', 'CLIPBOARD')
    sent = next((name for name in order if texts[name]), None)
    print('%-20s %s' % ('VMware sends', '%s %s' % (sent, preview(texts[sent])) if sent else 'nothing'))
    for hint in hints:
        print('-> ' + hint)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

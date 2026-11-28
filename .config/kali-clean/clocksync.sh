#!/usr/bin/env bash
# kali-clean: clocksync — keep this VM's clock on a domain controller's time.
#
#   clocksync DC_IP    set the clock to the DC's time and keep it there
#   clocksync          show the offset to that DC and what is holding the clock
#   clocksync off      give the clock back to normal time sync
#
# Kerberos refuses you when your clock is more than 5 minutes off the DC's
# (KRB_AP_ERR_SKEW, "Clock skew too great"). A one-off `sudo ntpdate DC` does
# not last in a VMware VM: VMware Tools puts the host's time back, every minute
# while "Synchronize guest time with host" is on and after any suspend, snapshot
# revert or Tools restart even when it is off, and systemd-timesyncd, chrony or
# ntpsec resync to the Internet. clocksync stops those, syncs to the DC, and
# checks it again every minute until `clocksync off`.
#
# What it changes, and `clocksync off` undoes:
#   * /etc/vmware-tools/tools.conf gets a marked "[timeSync] disable-all=true"
#     block (vmtoolsd rereads the file within 5 seconds, no restart);
#   * timedatectl set-ntp false, and chrony/ntpsec/openntpd stopped if running;
#   * kali-clean-clocksync, a transient systemd unit that runs ntpdate against
#     the DC once a minute (it does not survive a reboot: run clocksync again).
set -euo pipefail

prog=clocksync
unit=kali-clean-clocksync
conf=/etc/vmware-tools/tools.conf
others=(chrony.service ntpsec.service openntpd.service)
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/kali-clean"
state="$state_dir/clocksync.env"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$prog" "$*" >&2; }
die()  { warn "$*"; exit 1; }
as_root() { if [[ $(id -u) -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
usage() { sed -n '4,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

if [[ $(id -u) -eq 0 && -n "${SUDO_USER:-}" ]]; then
    die 'run it without sudo; it asks for sudo itself'
fi

ntp_tool() {
    if command -v ntpdate >/dev/null 2>&1; then echo ntpdate
    elif command -v ntpdig >/dev/null 2>&1; then echo ntpdig
    else die 'needs ntpdate: sudo apt install ntpsec-ntpdate'
    fi
}

# offset DC — how far the DC's clock is ahead of ours, in seconds (negative:
# ours is ahead); nothing when the DC does not answer NTP.
offset() {
    local out
    if [[ $(ntp_tool) == ntpdate ]]; then
        out="$(ntpdate -q -t 3 "$1" 2>/dev/null || true)"
    else
        out="$(ntpdig -t 3 "$1" 2>/dev/null || true)"
    fi
    # "2026-11-28 07:48:45.123 (+0100) +3600.123456 +/- 0.001 172.16.8.3 s1 no-leap"
    awk 'match($0, /\) [+-][0-9]+(\.[0-9]+)? /) { print substr($0, RSTART + 2, RLENGTH - 3); exit }' <<< "$out"
}

human() {   # 3725.4 -> "1h 2m 5s"
    awk -v s="$1" 'BEGIN { a = s < 0 ? -s : s; h = int(a / 3600); m = int((a % 3600) / 60); x = a % 60
        if (h) printf "%dh %dm %ds", h, m, x; else if (m) printf "%dm %ds", m, x; else printf "%.3fs", x }'
}

in_vmware() {
    [[ "$(systemd-detect-virt 2>/dev/null || true)" == vmware ]] || command -v vmtoolsd >/dev/null 2>&1
}

keeper_running() { systemctl is-active --quiet "$unit.service" 2>/dev/null; }

# tools_conf apply|revert|status — add or remove clocksync's block in tools.conf,
# leaving every other byte of the file alone.
tools_conf() {
    local -a run=(as_root)
    [[ $1 == status ]] && run=()
    "${run[@]}" python3 - "$conf" "$1" <<'PY'
import os, sys
path, action = sys.argv[1], sys.argv[2]
start = "# >>> kali-clean clocksync: VMware Tools may not set the clock (undo: clocksync off)"
start_new = start + " [new file]"
end = "# <<< kali-clean clocksync"
try:
    with open(path, "rb") as f:
        data = f.read().decode("utf-8", "surrogateescape")
    existed = True
except FileNotFoundError:
    data, existed = "", False

def find():
    for marker in (start, start_new):
        i = data.find("\n" + marker + "\n")
        if i >= 0:
            return i, marker
    return -1, None

def write(text, like_old):
    tmp = path + ".kali-clean-tmp"
    with open(tmp, "wb") as f:
        f.write(text.encode("utf-8", "surrogateescape"))
    if like_old:
        st = os.stat(path)
        os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, st.st_mode & 0o7777)
    else:
        os.chmod(tmp, 0o644)
    os.replace(tmp, path)

i, marker = find()
if action == "status":
    print("present" if i >= 0 else "absent")
elif action == "apply":
    if i >= 0:
        print("present")
    else:
        # tools.conf is a GLib key file: a [timeSync] group later in the file
        # adds to (and overrides) an earlier one.
        block = "\n%s\n[timeSync]\ndisable-all=true\n%s\n" % (start if existed else start_new, end)
        write(data + block, existed)
        print("added")
elif action == "revert":
    if i < 0:
        print("absent")
        sys.exit(0)
    j = data.find("\n" + end + "\n", i)
    if j < 0:
        sys.exit("clocksync: the marked block in %s is damaged; remove it by hand" % path)
    rest = data[:i] + data[j + len(end) + 2:]
    if marker == start_new and rest.strip() == "":
        os.remove(path)
        print("removed file")
    else:
        write(rest, True)
        print("removed")
PY
}

status() {
    local dc='' since='' off
    if [[ -r "$state" ]]; then
        dc="$(sed -n 's/^dc=//p' "$state")"
        since="$(sed -n 's/^since=//p' "$state")"
    fi
    if [[ -z "$dc" ]]; then
        say 'The clock is not held on a DC. Usage:'
        usage
        return 0
    fi
    say "Clock held on DC $dc since $since."
    off="$(offset "$dc")"
    if [[ -n "$off" ]]; then
        say "  offset now: $(human "$off") ($off s)"
    else
        say "  offset now: no NTP answer from $dc (UDP 123); is the VPN or pivot down?"
    fi
    if keeper_running; then
        say "  re-sync:    every minute ($unit)"
    else
        say "  re-sync:    not running (after a reboot?); run: clocksync $dc"
    fi
    if in_vmware; then
        if [[ "$(tools_conf status 2>/dev/null || true)" == present ]]; then
            say '  VMware:     cannot set the clock'
        else
            say "  VMware:     CAN set the clock (block missing from $conf)"
        fi
    fi
    say '  undo:       clocksync off'
}

hold() {
    local dc=$1 off now prev_dc='' since='' ntp_was svc result
    local -a stopped=()
    [[ "$dc" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || die "not an IP address or host name: $dc"
    ntp_tool >/dev/null
    as_root true || die 'needs sudo'

    off="$(offset "$dc")"
    [[ -n "$off" ]] || die "no NTP answer from $dc on UDP 123, nothing was changed. Is the VPN (or ligolo) up? A SOCKS pivot cannot carry NTP."

    # What was on before the first hold, so that `clocksync off` restores exactly that.
    ntp_was="$(timedatectl show -p NTP --value 2>/dev/null || echo no)"
    if [[ -r "$state" ]]; then
        prev_dc="$(sed -n 's/^dc=//p' "$state")"
        since="$(sed -n 's/^since=//p' "$state")"
        ntp_was="$(sed -n 's/^ntp=//p' "$state")"
        read -r -a stopped <<< "$(sed -n 's/^stopped=//p' "$state")"
    fi
    [[ "$prev_dc" == "$dc" && -n "$since" ]] || since="$(date '+%Y-%m-%d %H:%M')"

    if [[ "$(timedatectl show -p NTP --value 2>/dev/null || echo no)" == yes ]]; then
        as_root timedatectl set-ntp false
    fi
    for svc in "${others[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            as_root systemctl stop "$svc"
            stopped+=("$svc")
        fi
    done

    mkdir -p -- "$state_dir"
    printf 'dc=%s\nsince=%s\nntp=%s\nstopped=%s\n' "$dc" "$since" "$ntp_was" "${stopped[*]}" > "$state"

    if in_vmware; then
        if [[ -d "${conf%/*}" ]]; then
            result="$(tools_conf apply)"
            [[ "$result" == present ]] || sleep 6   # vmtoolsd rereads tools.conf every 5 seconds
        else
            warn "no ${conf%/*}; VMware Tools may still set the clock"
        fi
    fi

    if [[ $(ntp_tool) == ntpdate ]]; then
        as_root ntpdate -b -t 3 "$dc" >/dev/null || die "ntpdate $dc failed; see: clocksync"
    else
        as_root ntpdig -S -t 3 "$dc" >/dev/null || die "ntpdig $dc failed; see: clocksync"
    fi

    as_root systemctl stop "$unit.service" >/dev/null 2>&1 || true
    as_root systemctl reset-failed "$unit.service" >/dev/null 2>&1 || true
    # shellcheck disable=SC2016  # $1 is for the unit's own shell: the DC, passed as an argument
    if ! as_root systemd-run --quiet --unit="$unit" --description="kali-clean: keep the clock on DC $dc" \
            /bin/sh -c 'while :; do sleep 60; ntpdate -t 3 "$1" || ntpdig -s -S -M 500 -t 3 "$1" || :; done' \
            clocksync "$dc"; then
        warn 'could not start the once-a-minute re-sync; run clocksync again after a suspend'
    fi

    now="$(offset "$dc")"
    if [[ $off == -* ]]; then
        say "Clock set to DC $dc: it was $(human "$off") ahead."
    else
        say "Clock set to DC $dc: it was $(human "$off") behind."
    fi
    say "  offset now: $(human "${now:-0}"); VMware Tools and Internet time sync can no longer move it,"
    say '  and it is re-checked every minute. Back to normal: clocksync off'
}

release() {
    local ntp_was='' svc result
    local -a stopped=()
    as_root true || die 'needs sudo'
    if [[ -r "$state" ]]; then
        ntp_was="$(sed -n 's/^ntp=//p' "$state")"
        read -r -a stopped <<< "$(sed -n 's/^stopped=//p' "$state")"
    fi
    as_root systemctl stop "$unit.service" >/dev/null 2>&1 || true
    as_root systemctl reset-failed "$unit.service" >/dev/null 2>&1 || true
    if [[ -e "$conf" ]]; then
        result="$(tools_conf revert)"
        [[ "$result" == absent ]] || say "VMware Tools may set the clock again ($conf is as it was)."
    fi
    for svc in "${stopped[@]}"; do
        as_root systemctl start "$svc" || warn "could not start $svc again"
    done
    # Without a record (never held, or a manual `timedatectl set-ntp off`), normal means NTP on.
    if [[ ! -r "$state" || "$ntp_was" == yes ]]; then
        as_root timedatectl set-ntp true || warn 'could not turn NTP back on (timedatectl set-ntp true)'
    fi
    rm -f -- "$state"
    say 'Clock released: normal time sync is back.'
}

case "${1:-}" in
    '')                      status ;;
    off|release|stop|--off)  release ;;
    -h|--help|help)          usage ;;
    -*)                      usage >&2; exit 2 ;;
    *)                       hold "$1" ;;
esac

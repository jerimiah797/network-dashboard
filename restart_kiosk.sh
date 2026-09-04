#!/bin/sh
# Recycle the dashboard kiosk.
#
# For MANUAL use. NOT scheduled.
#
# A nightly cron ran this briefly on 2026-09-01 on the theory that chromium
# leaked. It does not: seven days of history showed memory flat while the kiosk
# ran 2d10h. The real loss was the 08-30 DNS forwarding loop, held in place by
# maxDBdays still being 91 here.
#
# TWO THINGS MUST BE TRUE BEFORE CHROMIUM STARTS
#
# 1. NOTHING ELSE IS RUNNING. A survivor is not a harmless leftover: the relaunch
#    opens a window in the existing process and silently drops every flag,
#    --kiosk included, so the kiosk comes back windowed with an address bar and
#    the script reports success. `pkill; sleep 5` is not enough for ten chromium
#    processes on a Pi 3 -- that is what broke it on 2026-09-01.
#
# 2. THE WAYLAND OUTPUT IS ON. Chromium asks the compositor for fullscreen at
#    startup. Ask while the output is off -- which it is any time swayidle has
#    blanked it -- and the request does not apply: the window comes up windowed
#    even though --kiosk is in argv. Verified both ways on 2026-09-04.
#
# COUNTING PROCESSES, CAREFULLY
#
# `pgrep -c` prints 0 AND exits non-zero when there is no match, so the obvious
# `$(pgrep -c ... || echo 0)` yields "0\n0" and every [ -eq ] then fails with
# "Illegal number". Same trap as `grep -c ... || echo 0`. Sanitise instead.

XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)")"
export WAYLAND_DISPLAY

[ -z "$WAYLAND_DISPLAY" ] && { echo "no wayland session; not restarting" >&2; exit 1; }

count_chromium() {
    n=$(pgrep -c -u "$(id -u)" chromium 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

pkill -u "$(id -u)" chromium 2>/dev/null

i=0
while [ "$i" -lt 20 ]; do
    [ "$(count_chromium)" -eq 0 ] && break
    i=$((i + 1))
    sleep 1
done

if [ "$(count_chromium)" -ne 0 ]; then
    pkill -9 -u "$(id -u)" chromium 2>/dev/null
    sleep 3
fi

remaining=$(count_chromium)
if [ "$remaining" -ne 0 ]; then
    echo "chromium still running ($remaining procs) after SIGKILL; NOT relaunching" >&2
    exit 1
fi

exec /home/jham/network-dashboard/start_kiosk.sh

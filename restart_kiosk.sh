#!/bin/sh
# Recycle the dashboard kiosk.
#
# For MANUAL use. NOT scheduled.
#
# A nightly cron ran this briefly on 2026-09-01 on the theory that chromium
# leaked. It does not. Seven days of node-exporter history showed available
# memory flat while the kiosk ran continuously for 2d10h. The memory hero
# actually lost went in an 85-minute cliff on 2026-08-30 12:00-13:15 -- the DNS
# forwarding loop -- and stayed gone because maxDBdays was still 91 here, so FTL
# re-imported the bloated history at every start. Fixing retention fixed it.
#
# WAIT FOR CHROMIUM TO ACTUALLY EXIT (added 2026-09-04)
#
# This script previously did `pkill; sleep 5; exec start_kiosk.sh`. Five seconds
# is not enough for ten chromium processes to die on a Pi 3, and if ANY survive
# the relaunch does not start a new browser -- it opens a window in the existing
# one and silently drops every flag, because they are process-level. The kiosk
# then runs windowed, with browser chrome, showing whatever the old instance had.
#
# That is what happened here: the 09-01 recycle left a windowed browser whose
# tab was later discarded by Memory Saver, so the panel showed a blank page and
# taps could not wake it for three days. The relaunch reported success.
#
# So: poll until the count is genuinely zero, escalate to SIGKILL, and refuse to
# launch rather than launch into a broken state.

XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)")"
export WAYLAND_DISPLAY

[ -z "$WAYLAND_DISPLAY" ] && { echo "no wayland session; not restarting" >&2; exit 1; }

pkill -u "$(id -u)" chromium 2>/dev/null

i=0
while [ "$i" -lt 20 ]; do
    [ "$(pgrep -c -u "$(id -u)" chromium 2>/dev/null || echo 0)" -eq 0 ] && break
    i=$((i + 1))
    sleep 1
done

if [ "$(pgrep -c -u "$(id -u)" chromium 2>/dev/null || echo 0)" -ne 0 ]; then
    pkill -9 -u "$(id -u)" chromium 2>/dev/null
    sleep 3
fi

remaining=$(pgrep -c -u "$(id -u)" chromium 2>/dev/null || echo 0)
if [ "$remaining" -ne 0 ]; then
    # Launching now would attach to the survivor and drop every flag, which is
    # exactly the silent-breakage this guard exists to prevent.
    echo "chromium still running ($remaining procs) after SIGKILL; NOT relaunching" >&2
    exit 1
fi

exec /home/jham/network-dashboard/start_kiosk.sh

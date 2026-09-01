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
# Use this after changing the dashboard, or if the panel is wedged.
#
# hero is the DNS failover, so memory exhaustion here is not cosmetic -- it is
# the condition that stops it taking over when the primary dies.
#
# Runs from cron as jham. The Wayland session variables must be set explicitly:
# cron has no session, and without them chromium cannot reattach to the
# compositor and the screen stays black.

XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
WAYLAND_DISPLAY="$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)")"
export WAYLAND_DISPLAY

[ -z "$WAYLAND_DISPLAY" ] && { echo "no wayland session; not restarting"; exit 0; }

pkill -u "$(id -u)" chromium 2>/dev/null
sleep 5

exec /home/jham/network-dashboard/start_kiosk.sh

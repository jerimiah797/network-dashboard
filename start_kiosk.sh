#!/bin/sh
# Launch the network dashboard fullscreen on hero's attached screen.
#
# Called from ~/.config/labwc/autostart at session start (lightdm autologins
# jham into the rpd-labwc Wayland session).
#
# --force-device-scale-factor=0.8 is the "two zoom steps down" that makes the
# dashboard fit this screen: Chromium's zoom ladder is 100 -> 90 -> 80.
#
# The wait loop matters. The session starts before network-dashboard.service is
# necessarily answering, and Chromium caches the failed load -- you get an error
# page in kiosk mode with no chrome to retry from.
#
# Separate --user-data-dir on purpose: if a Chromium instance is already running
# on the default profile, a second launch just opens a window in the EXISTING
# process and the flags above are silently ignored, because they are
# process-level. A dedicated profile also means no "restore pages?" prompt after
# an unclean shutdown, which on a Pi that loses power is every time.
#
# THE DISCARDED-TAB FAILURE (2026-09-04)
#
# The panel sat dark for three days and taps did nothing. The cause was not the
# backlight and not the digitiser: Chromium had DISCARDED the tab. Memory Saver
# drops the renderer of an inactive tab to reclaim RAM, leaving the tab shell
# with the right URL and no document -- a blank white page.
#
# On a kiosk that is the worst possible failure, because it is silent and it
# disables the recovery path. No document means no JavaScript, so the click
# handler in index.html never runs, so set_brightness() is never called and a tap
# cannot wake the screen. hero_backlight_brightness sat at 0 for three days while
# every other metric read healthy.
#
# A kiosk tab is "inactive" by definition -- nobody switches to it, and on a
# 905 MB Pi memory pressure is routine -- so this was going to happen eventually.
# The four flags below turn off discarding and the throttling that precedes it.
# Feature names have changed across Chromium versions; unknown names in
# --disable-features are ignored, so all the spellings are listed on purpose.

URL="http://localhost:5000/"

i=0
while [ "$i" -lt 60 ]; do
    if curl -sf -o /dev/null --max-time 2 "$URL"; then break; fi
    i=$((i + 1))
    sleep 2
done

exec chromium \
    --kiosk \
    --ozone-platform=wayland \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-features=TranslateUI,MemorySaver,MemorySaverModeAvailable,HighEfficiencyModeAvailable,BatterySaverModeAvailable \
    --disable-background-timer-throttling \
    --disable-backgrounding-occluded-windows \
    --disable-renderer-backgrounding \
    --no-first-run \
    --password-store=basic \
    --user-data-dir="$HOME/.config/chromium-kiosk" \
    --force-device-scale-factor=0.8 \
    "$URL"

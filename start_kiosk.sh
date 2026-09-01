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
    --disable-features=TranslateUI \
    --password-store=basic \
    --user-data-dir="$HOME/.config/chromium-kiosk" \
    --force-device-scale-factor=0.8 \
    "$URL"

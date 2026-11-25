#!/bin/sh
# Installs or upgrades the widget for the current user.
set -e
cd "$(dirname "$0")"
if kpackagetool6 --type Plasma/Applet --show org.taghouti.rephraser >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --upgrade package
    echo "Upgraded. Restart Plasma to load the new version: systemctl --user restart plasma-plasmashell"
else
    kpackagetool6 --type Plasma/Applet --install package
    echo "Installed. Right-click a panel or the desktop, choose Add or Manage Widgets, and search for Rephraser."
fi

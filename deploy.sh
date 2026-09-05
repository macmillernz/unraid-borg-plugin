#!/bin/bash
# Dev-cycle deploy: rsync source/borgbackup straight to a real Unraid test
# box's plugin dir, skipping the .plg/.txz packaging step entirely.
# Requires SSH access to the box.
#
# Note: this is dev-only convenience - it does NOT survive a reboot on its
# own (/usr/local/emhttp is rebuilt from OS packages every boot). For a real
# persistent install use package.sh + a release (see README).
#
# Usage:
#   BORG_UI_HOST=root@10.0.60.3 ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${BORG_UI_HOST:?Set BORG_UI_HOST to user@host of the test box}"

rsync -av --delete --exclude '.DS_Store' \
  source/borgbackup/ "${BORG_UI_HOST}:/usr/local/emhttp/plugins/borgbackup/"

ssh "${BORG_UI_HOST}" '
  find /usr/local/emhttp/plugins/borgbackup -type f -exec chmod 644 {} +
  find /usr/local/emhttp/plugins/borgbackup -type d -exec chmod 755 {} +
  # emhttp and cron exec() these directly - without +x the backup silently
  # never runs and the web buttons report a missing binary.
  chmod +x /usr/local/emhttp/plugins/borgbackup/scripts/* \
           /usr/local/emhttp/plugins/borgbackup/event/started/borgbackup
  mkdir -p /boot/config/plugins/borgbackup
'

echo "Deployed to ${BORG_UI_HOST}."
echo "Open Settings -> Utilities -> Borg Backup. The tab list is cached"
echo "per-session, so if it does not appear yet, force-refresh the page."
echo
echo "Note: rsync --delete does not touch /boot/config/plugins/borgbackup,"
echo "so your settings, passphrase and container selections are preserved."

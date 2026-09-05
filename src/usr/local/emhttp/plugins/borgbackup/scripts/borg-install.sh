#!/bin/bash
# borg-install.sh - fetch the official standalone borg binary.
#
#   borg-install.sh [VERSION]
#
# Borg is not part of Unraid and /usr/local/bin does not survive a reboot, so
# the binary is kept on the flash drive and re-linked at boot by the plugin's
# `started` event script.
#
# Upstream asset names have changed between releases (borg-linux64 through to
# the glibc-suffixed names), and which one runs depends on the glibc in the
# running Unraid build - so candidates are tried in turn and each is only
# accepted once it actually executes.

set -u

PLUGIN=borgbackup
BOOT=/boot/config/plugins/$PLUGIN
TARGET=$BOOT/borg
LINK=/usr/local/bin/borg
VERSION=${1:-1.4.1}
BASE=https://github.com/borgbackup/borg/releases/download/$VERSION

CANDIDATES=(borg-linux-glibc236 borg-linux-glibc231 borg-linuxnew64 borg-linux64)

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BOOT" || die "cannot write to $BOOT"
TMP=$(mktemp /tmp/borg-dl.XXXXXX) || die "cannot create temp file"
trap 'rm -f "$TMP"' EXIT

say "Installing borg $VERSION ..."

installed=""
for asset in "${CANDIDATES[@]}"; do
  say "  trying $asset"
  if ! curl -fsSL --connect-timeout 15 --max-time 600 -o "$TMP" "$BASE/$asset"; then
    say "    not available"
    continue
  fi
  chmod +x "$TMP"
  # A binary built against a newer glibc downloads fine and then fails to run,
  # so the version call is the real test.
  if out=$("$TMP" --version 2>&1); then
    say "    ok: $out"
    installed=$asset
    break
  fi
  say "    downloaded but will not run here: $out"
done

[[ -n $installed ]] || die "no usable borg build found for $VERSION (tried: ${CANDIDATES[*]})"

# The running binary cannot be overwritten in place while a backup is using it.
if pgrep -f '/borg-backup\.sh' >/dev/null 2>&1; then
  die "a backup is currently running - try again once it finishes"
fi

cp -f "$TMP" "$TARGET.new" || die "cannot write $TARGET.new"
chmod +x "$TARGET.new"
mv -f "$TARGET.new" "$TARGET" || die "cannot replace $TARGET"

install -D -m 0755 "$TARGET" "$LINK" || die "cannot install $LINK"

say "Installed: $("$LINK" --version)"
say "Binary kept at $TARGET and restored to $LINK on every boot."

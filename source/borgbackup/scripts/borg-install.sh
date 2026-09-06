#!/bin/bash
# borg-install.sh - fetch the official standalone borg binary.
#
#   borg-install.sh [VERSION]
#
# Borg is not part of Unraid and /usr/local/bin does not survive a reboot, so
# the binary is kept on the flash drive and re-linked at boot by the plugin's
# `started` event script.
#
# The download is ~26MB, which is far too slow to sit inside a web request -
# the web UI runs this detached and tails our stdout, so everything here is
# written to be readable as it happens rather than summarised at the end.

set -u

PLUGIN=borgbackup
BOOT=/boot/config/plugins/$PLUGIN
PLUGIN_DIR=/usr/local/emhttp/plugins/$PLUGIN
TARGET=$BOOT/borg
LINK=/usr/local/bin/borg
VERSION=${1:-1.4.1}

# Printed on exit so the UI can stop polling without racing the process table.
DONE_MARKER=__BORG_INSTALL_DONE__

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*"; exit 1; }

# One trap for the whole script. rc must be captured first: inside the handler
# $? becomes the status of whatever the handler last ran.
cleanup() {
  local rc=$?
  rm -f "${TMP:-}"
  printf '%s %s\n' "$DONE_MARKER" "$rc"
}
trap cleanup EXIT

# No buffering games needed: the caller redirects stdout to a file, and each
# echo is its own write, so a tail sees lines as they are produced.

say "Installing borg $VERSION"
say "Target: $TARGET (kept on the flash drive, re-linked to $LINK at boot)"

if pgrep -f '/borg-backup\.sh' >/dev/null 2>&1; then
  die "a backup is running - the borg binary cannot be replaced while it is in use"
fi

mkdir -p "$BOOT" || die "cannot write to $BOOT"
TMP=$(mktemp /tmp/borg-dl.XXXXXX) || die "cannot create a temp file"

# ------------------------------------------------------------------- glibc --

step "Checking this server's glibc"
GLIBC=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
if [[ -n $GLIBC ]]; then
  say "glibc $GLIBC - builds requiring newer than this will be skipped"
else
  say "could not determine glibc version; every Linux build will be tried"
  GLIBC=0
fi

# ------------------------------------------------------------- asset lookup --

step "Looking up the downloads published for borg $VERSION"
if ! CANDIDATES=$(php -q "$PLUGIN_DIR/scripts/borg-assets.php" "$VERSION" "$GLIBC" 2>&1) \
   || [[ -z $CANDIDATES ]]; then
  say "${CANDIDATES:-no response from the GitHub API}"
  say ""
  say "Falling back to the known asset names for this release series."
  base="https://github.com/borgbackup/borg/releases/download/$VERSION"
  CANDIDATES=$(printf '%s\t%s/%s\n' \
    borg-linux-glibc236 "$base" borg-linux-glibc236 \
    borg-linux-glibc231 "$base" borg-linux-glibc231 \
    borg-linux-glibc228 "$base" borg-linux-glibc228 \
    borg-linux64        "$base" borg-linux64)
fi

say "Will try, best first:"
while IFS=$'\t' read -r name _; do [[ -n $name ]] && say "  - $name"; done <<<"$CANDIDATES"

# ----------------------------------------------------------------- download --

installed=""
while IFS=$'\t' read -r name url; do
  [[ -n $name && -n $url ]] || continue

  step "Downloading $name"
  say "$url"

  # curl's own meters (default and --progress-bar) redraw with carriage
  # returns, which collapse into one unreadable line when this log is shown in
  # the browser. Run it quietly in the background and report the growing file
  # size instead, so the window shows steady progress on a ~26MB download.
  : >"$TMP"
  curl -fsSL --connect-timeout 15 --max-time 300 --retry 2 --retry-delay 3 \
       -o "$TMP" "$url" &
  cpid=$!
  while kill -0 "$cpid" 2>/dev/null; do
    sleep 2
    kill -0 "$cpid" 2>/dev/null || break
    sz=$(stat -c%s "$TMP" 2>/dev/null || echo 0)
    say "    $(( sz / 1048576 )) MB so far..."
  done
  if ! wait "$cpid"; then
    say "    not available, or the download failed - trying the next build"
    continue
  fi
  say "    downloaded $(( $(stat -c%s "$TMP" 2>/dev/null || echo 0) / 1048576 )) MB"

  size=$(stat -c%s "$TMP" 2>/dev/null || echo 0)
  if [[ $size -lt 1000000 ]]; then
    say "    only $size bytes - that is not a borg binary, trying the next build"
    continue
  fi

  chmod +x "$TMP"
  step "Verifying $name actually runs on this server"
  if out=$("$TMP" --version 2>&1); then
    say "    $out"
    installed=$name
    break
  fi
  say "    downloaded, but it will not run here:"
  say "    $out"
done <<<"$CANDIDATES"

[[ -n $installed ]] || die "no usable borg build was found for version $VERSION"

# ------------------------------------------------------------------ install --

step "Installing"
cp -f "$TMP" "$TARGET.new"      || die "cannot write $TARGET.new"
chmod +x "$TARGET.new"
mv -f "$TARGET.new" "$TARGET"   || die "cannot replace $TARGET"
install -D -m 0755 "$TARGET" "$LINK" || die "cannot install $LINK"

say "Installed $installed as $("$LINK" --version)"
say ""
say "Kept at $TARGET so it survives a reboot; the array-start hook copies it"
say "back to $LINK each boot."
say ""
say "Done."

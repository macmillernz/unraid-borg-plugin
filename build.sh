#!/usr/bin/env bash
# build.sh - package the plugin as a Slackware .txz and update the .plg to match.
#
#   ./build.sh [VERSION]        default: today's date, YYYY.MM.DD
#
# Runs on macOS (bsdtar) or Linux (GNU tar). The archive must be owned by
# root:root with sane modes, because Unraid unpacks it straight over
# /usr/local/emhttp - so ownership is forced rather than inherited from
# whoever happens to be building.

set -euo pipefail

NAME=borgbackup
ROOT=$(cd "$(dirname "$0")" && pwd)
SRC=$ROOT/src
PLG=$ROOT/plugin/$NAME.plg
OUT=$ROOT/archive
VERSION=${1:-$(date +%Y.%m.%d)}
# Kept in step with the GitHub account in plugin/borgbackup.plg.
GHUSER=${GHUSER:-macmillernz}
TXZ=$OUT/$NAME-$VERSION.txz

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -d $SRC ]] || die "missing $SRC"
[[ -f $PLG ]] || die "missing $PLG"

# ------------------------------------------------------------------ checks --

echo "==> Checking sources"
fail=0
while IFS= read -r -d '' f; do
  bash -n "$f" || { echo "  bad shell syntax: $f"; fail=1; }
done < <(find "$SRC" -type f \( -name '*.sh' -o -path '*/event/*' \) -print0)

if command -v xmllint >/dev/null; then
  xmllint --noout "$PLG" || { echo "  bad XML: $PLG"; fail=1; }
fi
if command -v node >/dev/null; then
  node --check "$SRC/usr/local/emhttp/plugins/$NAME/images/borg.js" \
    || { echo "  bad JS"; fail=1; }
fi
if command -v php >/dev/null; then
  while IFS= read -r -d '' f; do
    php -l "$f" >/dev/null || { echo "  bad PHP: $f"; fail=1; }
  done < <(find "$SRC" -type f \( -name '*.php' -o -name '*.page' \) -print0)
else
  echo "  (php not installed - skipping PHP lint; run 'make lint' with Docker)"
fi
[[ $fail == 0 ]] || die "source checks failed"

# ----------------------------------------------------------------- staging --

echo "==> Staging"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/$NAME-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

# `cp -R src/.` rather than `src` so the tree lands at the stage root.
cp -R "$SRC/." "$STAGE/"
find "$STAGE" -name '.DS_Store' -delete

# Executables vs. web assets - Unraid runs the first group directly.
find "$STAGE" -type f -exec chmod 0644 {} +
find "$STAGE" -type d -exec chmod 0755 {} +
chmod 0755 "$STAGE/usr/local/emhttp/plugins/$NAME/scripts/"*.sh \
           "$STAGE/usr/local/emhttp/plugins/$NAME/scripts/"*.php \
           "$STAGE/usr/local/emhttp/plugins/$NAME/event/started/$NAME"

mkdir -p "$STAGE/install"
cat > "$STAGE/install/slack-desc" <<DESC
       |-----handy-ruler------------------------------------------------------|
borgbackup: borgbackup (BorgBackup for Unraid)
borgbackup:
borgbackup: Scheduled, deduplicated, encrypted backups of your Docker
borgbackup: containers using BorgBackup. Choose all containers or individual
borgbackup: ones, and pick exactly which of each container's mounts to
borgbackup: archive. Supports local and remote (SSH) repositories, per
borgbackup: container retention, and optional stop/start around each archive.
borgbackup:
borgbackup: Homepage: https://github.com/$GHUSER/unraid-borg-plugin
borgbackup: Borg:     https://www.borgbackup.org/
borgbackup:
DESC

# --------------------------------------------------------------- packaging --

echo "==> Packaging $TXZ"
mkdir -p "$OUT"
rm -f "$TXZ"

TAR_ARGS=(--uid 0 --gid 0 --uname root --gname root)
if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
  TAR_ARGS=(--owner=0 --group=0)
fi
COPYFILE_DISABLE=1 tar -C "$STAGE" -cJf "$TXZ" "${TAR_ARGS[@]}" .

MD5=$(md5sum "$TXZ" 2>/dev/null | cut -d' ' -f1 || md5 -q "$TXZ")
SIZE=$(du -h "$TXZ" | cut -f1)

# ------------------------------------------------------- sync the manifest --

echo "==> Updating $PLG"
# Rewrite only the two entities that change per build, so hand edits survive.
perl -pi -e "s|(<!ENTITY version\s+\")[^\"]*(\")|\${1}$VERSION\${2}|;
             s|(<!ENTITY md5\s+\")[^\"]*(\")|\${1}$MD5\${2}|" "$PLG"

if command -v xmllint >/dev/null; then xmllint --noout "$PLG"; fi

cat <<EOF

Built $NAME $VERSION
  package : $TXZ ($SIZE)
  md5     : $MD5
  manifest: $PLG

Publish by committing both archive/$NAME-$VERSION.txz and plugin/$NAME.plg,
then installing from the raw URL of the .plg on the Unraid Plugins page.
EOF

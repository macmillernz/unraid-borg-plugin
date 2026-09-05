#!/bin/bash
# Builds source/borgbackup into a Slackware-style .txz for borgbackup.plg to
# download. The archive's internal paths are rooted at / so
# `upgradepkg --install-new` extracts straight to
# /usr/local/emhttp/plugins/borgbackup/.
#
# Version follows year.month.day.n (bump n each same-day release, reset to 1
# on a new day) and lives in exactly one place: borgbackup.plg's
# <!ENTITY version ...>. Defaults to that value so the built package and the
# descriptor can never drift out of sync.
#
#   ./package.sh              build at the version currently in the .plg
#   ./package.sh --bump       advance to today's next version, then build
#   ./package.sh 2026.09.06.2 build at an explicit version
#
# Unlike filesUI's package.sh this writes the MD5 back into the .plg itself
# rather than asking you to paste it: the checksum is of the file we just
# built, so there is nothing a human needs to decide, and a stale MD5 makes
# the plugin manager reject the download as corrupt.
#
# Runs on macOS (bsdtar) or Linux (GNU tar). Ownership is forced to root:root
# because Unraid unpacks this straight over /usr/local/emhttp - without it the
# package carries whatever uid happened to build it.

set -euo pipefail
cd "$(dirname "$0")"

NAME=borgbackup
PLG=$NAME.plg
SRCDIR=source/$NAME

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -d $SRCDIR ]] || die "missing $SRCDIR"
[[ -f $PLG ]]    || die "missing $PLG"

plg_version() { grep -o '<!ENTITY version *"[^"]*"' "$PLG" | sed -E 's/.*"([^"]*)"/\1/'; }

PLG_VERSION=$(plg_version)
[[ -n $PLG_VERSION ]] || die "could not read <!ENTITY version ...> from $PLG"

# ------------------------------------------------------------------ version --

case "${1:-}" in
  --bump)
    today=$(date +%Y.%m.%d)
    if [[ $PLG_VERSION == "$today".* ]]; then
      # Same day: advance the counter rather than silently rebuilding over
      # an already-released package.
      VERSION="$today.$(( ${PLG_VERSION##*.} + 1 ))"
    else
      VERSION="$today.1"
    fi
    ;;
  '') VERSION=$PLG_VERSION ;;
  *)  VERSION=$1 ;;
esac

[[ $VERSION =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]] \
  || die "version must look like 2026.09.05.1 (got '$VERSION')"

# ------------------------------------------------------------------- checks --

echo "==> Checking sources"
fail=0
while IFS= read -r -d '' f; do
  bash -n "$f" || { echo "  bad shell syntax: $f"; fail=1; }
done < <(find "$SRCDIR" -type f \( -name '*.sh' -o -path '*/event/*' \) -print0)

command -v xmllint >/dev/null && { xmllint --noout "$PLG" || { echo "  bad XML: $PLG"; fail=1; }; }
command -v node    >/dev/null && { node --check "$SRCDIR/images/borg.js" || fail=1; }

if command -v php >/dev/null; then
  while IFS= read -r -d '' f; do
    php -l "$f" >/dev/null || { echo "  bad PHP: $f"; fail=1; }
  done < <(find "$SRCDIR" -type f \( -name '*.php' -o -name '*.page' \) -print0)
else
  echo "  (php not installed - skipping PHP lint; run 'make lint' with Docker)"
fi
[[ $fail == 0 ]] || die "source checks failed"

# ------------------------------------------------------------------ staging --

echo "==> Staging"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/$NAME-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/usr/local/emhttp/plugins"
cp -R "$SRCDIR" "$STAGE/usr/local/emhttp/plugins/$NAME"
find "$STAGE" -name '.DS_Store' -delete

# Pages, assets and includes are read by the webserver, never executed.
find "$STAGE" -type f -exec chmod 0644 {} +
find "$STAGE" -type d -exec chmod 0755 {} +
# scripts/ and the array-start event hook are exec()d directly - a 644 here
# means backups silently never run.
chmod 0755 "$STAGE/usr/local/emhttp/plugins/$NAME/scripts/"* \
           "$STAGE/usr/local/emhttp/plugins/$NAME/event/started/$NAME"

mkdir -p "$STAGE/install"
cat > "$STAGE/install/slack-desc" <<'DESC'
       |-----handy-ruler------------------------------------------------------|
borgbackup: borgbackup (BorgBackup for Unraid)
borgbackup:
borgbackup: Scheduled, deduplicated, encrypted backups of your Docker
borgbackup: containers using BorgBackup. Choose all containers or individual
borgbackup: ones, and pick exactly which of each container's mounts to
borgbackup: archive. Supports local and remote (SSH) repositories, per
borgbackup: container retention, and optional stop/start around each archive.
borgbackup:
borgbackup: Homepage: https://github.com/macmillernz/unraid-borg-plugin
borgbackup: Borg:     https://www.borgbackup.org/
borgbackup:
DESC

# ---------------------------------------------------------------- packaging --

# name-version-arch-build: Slackware strips the last three fields to identify
# a package, so without the suffix upgradepkg cannot see one .txz as an upgrade
# of another and leaves removed files behind. Must match &txz; in the .plg.
OUT="$NAME-$VERSION-x86_64-1.txz"
echo "==> Packaging $OUT"
rm -f "$OUT"

TAR_ARGS=(--uid 0 --gid 0 --uname root --gname root)
tar --version 2>/dev/null | grep -qi 'gnu tar' && TAR_ARGS=(--owner=0 --group=0)
COPYFILE_DISABLE=1 tar -C "$STAGE" -cJf "$OUT" "${TAR_ARGS[@]}" install usr

MD5=$(md5sum "$OUT" 2>/dev/null | cut -d' ' -f1 || md5 -q "$OUT")

# -------------------------------------------------------- sync the manifest --

echo "==> Updating $PLG"
# Rewrite only the two entities that change per build, so hand edits survive.
perl -pi -e "s|(<!ENTITY version\s+\")[^\"]*(\")|\${1}$VERSION\${2}|;
             s|(<!ENTITY MD5\s+\")[^\"]*(\")|\${1}$MD5\${2}|" "$PLG"

command -v xmllint >/dev/null && xmllint --noout "$PLG"

cat <<EOF

Built $OUT
  version : $VERSION
  MD5     : $MD5  (written into $PLG)

Next:
  gh release create $VERSION $OUT --title "$NAME $VERSION" --notes "See CHANGES in $PLG"
  git add -A && git commit -m "Release $VERSION" && git push
EOF

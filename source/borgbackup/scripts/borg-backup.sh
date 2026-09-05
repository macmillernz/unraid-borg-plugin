#!/bin/bash
# borg-backup.sh - run a Borg backup for the containers selected in the web UI.
#
#   borg-backup.sh [--dry-run] [--container NAME]
#
# Deliberately does not use `set -e`: a stopped container must always be
# started again, even when borg fails half way through.

PLUGIN=borgbackup
BOOT=/boot/config/plugins/$PLUGIN
PLUGIN_DIR=/usr/local/emhttp/plugins/$PLUGIN
CFG=$BOOT/$PLUGIN.cfg
DEFAULTS=$PLUGIN_DIR/default.cfg
LOG=/var/log/$PLUGIN.log
STATE=/var/local/emhttp/$PLUGIN.state
LOCK=/var/run/$PLUGIN.lock
NOTIFY=/usr/local/emhttp/webGui/scripts/notify

DRY_RUN=0
ONLY_CONTAINER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --container) ONLY_CONTAINER="$2"; shift 2 ;;
    -h|--help)   sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

# ---------------------------------------------------------------- logging --

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }
info() { log "[info]  $*"; }
warn() { log "[warn]  $*"; WARNINGS=$((WARNINGS+1)); }
err()  { log "[error] $*"; LAST_ERROR="$*"; }

WARNINGS=0
FAILURES=0
ARCHIVED=0
LAST_ERROR=""
STOPPED_CONTAINERS=()

# Keep the log from growing without bound (roughly 2MB, one generation).
if [[ -f $LOG && $(stat -c%s "$LOG" 2>/dev/null || echo 0) -gt 2097152 ]]; then
  mv -f "$LOG" "$LOG.1" 2>/dev/null
fi
touch "$LOG" 2>/dev/null

# ------------------------------------------------------------------ config --

[[ -r $DEFAULTS ]] && . "$DEFAULTS"
[[ -r $CFG ]]      && . "$CFG"

BORG_BIN=""
for c in /usr/local/bin/borg "$BOOT/borg"; do
  [[ -x $c ]] && { BORG_BIN=$c; break; }
done

finish() {
  local result=$1
  local dur=$(( $(date +%s) - START_TS ))
  # A dry run must not look like a completed backup on the status panel.
  [[ $DRY_RUN == 1 && $result != failed ]] && result="dry-run"

  cat >"$STATE" <<EOS
LAST_RUN="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_RESULT="$result"
LAST_DURATION="$dur"
LAST_ARCHIVES="$ARCHIVED"
LAST_ERROR="${LAST_ERROR//\"/}"
EOS
  info "Finished: $result (${dur}s, $ARCHIVED archive(s), $FAILURES failure(s), $WARNINGS warning(s))"

  [[ $DRY_RUN == 1 ]] && return 0          # nothing happened worth notifying about
  case "$NOTIFY" in
    all)     notify_user "$result" ;;
    failure) [[ $result != success ]] && notify_user "$result" ;;
  esac
}

notify_user() {
  [[ -x $NOTIFY ]] || return 0
  local result=$1 icon=normal subject
  case "$result" in
    success)  icon=normal;  subject="Borg backup completed" ;;
    warning)  icon=warning; subject="Borg backup completed with warnings" ;;
    *)        icon=alert;   subject="Borg backup FAILED" ;;
  esac
  "$NOTIFY" -e "Borg Backup" -s "$subject" \
    -d "$ARCHIVED archive(s), $FAILURES failure(s), $WARNINGS warning(s)${LAST_ERROR:+ - $LAST_ERROR}" \
    -i "$icon" >/dev/null 2>&1
}

# Always bring back anything we stopped, whatever killed us.
cleanup() {
  local rc=$1
  rm -f "${PLAN:-}"
  restart_stopped
  exit "$rc"
}

restart_stopped() {
  local c
  for c in "${STOPPED_CONTAINERS[@]}"; do
    info "Starting container '$c'"
    if ! docker start "$c" >/dev/null 2>&1; then
      err "Failed to restart container '$c' - start it manually"
      FAILURES=$((FAILURES+1))
    fi
  done
  STOPPED_CONTAINERS=()
}

# --------------------------------------------------------------- preflight --

START_TS=$(date +%s)
info "===== Borg backup starting${ONLY_CONTAINER:+ (container: $ONLY_CONTAINER)} ====="
[[ $DRY_RUN == 1 ]] && info "Dry run - no archives will be written"

bail() { err "$1"; finish failed; exit "${2:-1}"; }

[[ -n $BORG_BIN ]] || bail "borg binary not found - install it from the plugin's Settings page"
[[ -n $REPO ]]     || bail "No repository configured - set one on the Settings page"

# --------------------------------------------------------------- passphrase --

export BORG_REPO="$REPO"
export BORG_RELOCATED_REPO_ACCESS_IS_OK=no
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=no
# Never block on an interactive prompt from a cron run.
export BORG_HOST_ID_NOT_UNIQUE_IS_OK=yes

case "$PASSPHRASE_MODE" in
  file)
    [[ -r $PASSPHRASE_FILE ]] || bail "Passphrase file '$PASSPHRASE_FILE' is missing or unreadable"
    export BORG_PASSPHRASE
    BORG_PASSPHRASE=$(<"$PASSPHRASE_FILE")
    ;;
  *)
    if [[ -r $BOOT/passphrase ]]; then
      export BORG_PASSPHRASE
      BORG_PASSPHRASE=$(<"$BOOT/passphrase")
    else
      warn "No passphrase stored - this only works for an unencrypted repository"
    fi
    ;;
esac
# A trailing newline in the file is almost always an editing artefact, not part
# of the passphrase.
BORG_PASSPHRASE=${BORG_PASSPHRASE%$'\n'}

if [[ -n $SSH_KEY ]]; then
  export BORG_RSH="ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
fi

# Single run at a time; a slow backup must not overlap the next cron tick.
exec 9>"$LOCK"
if ! flock -n 9; then
  err "Another backup is already running - aborting this run"
  finish skipped
  exit 75
fi

# ------------------------------------------------------------------- repo --

if ! "$BORG_BIN" info --lock-wait 60 >>"$LOG" 2>&1; then
  bail "Cannot open repository '$REPO' - check the location, passphrase and that it is initialised"
fi
info "Repository '$REPO' opened"

# ------------------------------------------------------------------- plan --

PLAN=$(mktemp /tmp/borg-plan.XXXXXX) || bail "Cannot create temp file"
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

if ! php -q "$PLUGIN_DIR/scripts/borg-plan.php" >"$PLAN" 2>>"$LOG"; then
  bail "Could not build a backup plan - see the messages above"
fi

# ----------------------------------------------------------------- helpers --

# Turn the archive-name template into a glob matching only this container's
# archives, so pruning one container never touches another's.
archive_glob() {
  # NB: two `local` statements, not one. Bash expands every word of a `local`
  # command before performing any of its assignments, so `local a=$1 b=$a`
  # would expand $a while it is still empty.
  local name=$1
  local g=${ARCHIVE_FORMAT//\{container\}/$name}
  # Any remaining {placeholder} is resolved by borg at archive time, so it
  # becomes a wildcard here.
  g=$(printf '%s' "$g" | sed -E 's/\{[^}]*\}/*/g; s/\*+/*/g')
  # A format without {container} would otherwise yield a glob that matches
  # every container's archives - refuse to prune on that.
  [[ $g == *"$name"* ]] || { printf '%s' ''; return 1; }
  printf '%s' "$g"
}

archive_name() {
  printf '%s' "${ARCHIVE_FORMAT//\{container\}/$1}"
}

# `--glob-archives` in borg 1.2, renamed `--match-archives` in 1.4+.
BORG_VERSION=$("$BORG_BIN" --version 2>/dev/null | awk '{print $2}')
case "$BORG_VERSION" in
  1.0*|1.1*|1.2*|1.3*) MATCH_FLAG='--glob-archives'; MATCH_PREFIX='' ;;
  *)                   MATCH_FLAG='--match-archives'; MATCH_PREFIX='sh:' ;;
esac
info "Using borg $BORG_VERSION"

stop_container() {
  local c=$1
  info "Stopping container '$c'"
  if docker stop -t "${STOP_TIMEOUT:-60}" "$c" >/dev/null 2>&1; then
    STOPPED_CONTAINERS+=("$c")
    return 0
  fi
  warn "Could not stop '$c' - archiving it live"
  return 1
}

# ------------------------------------------------------------- run the plan --

run_container() {
  local name=$1 stop=$2
  shift 2
  local -a paths=() excludes=()
  local a
  for a in "$@"; do
    case "$a" in
      P*) paths+=("${a#P}") ;;
      X*) excludes+=("${a#X}") ;;
    esac
  done

  [[ ${#paths[@]} -gt 0 ]] || { warn "No paths for '$name' - skipped"; return; }

  local was_running=0
  if [[ $stop == 1 && $DRY_RUN == 0 ]]; then
    if [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == true ]]; then
      was_running=1
      stop_container "$name"
    fi
  fi

  local -a args=(create
    --show-rc --lock-wait 120
    --compression "${COMPRESSION:-zstd,3}"
    --exclude-caches)
  if [[ $DRY_RUN == 1 ]]; then args+=(--dry-run --list); else args+=(--stats); fi
  [[ ${LOG_LEVEL:-info} == debug ]] && args+=(--debug)
  for a in "${excludes[@]}"; do args+=(--exclude "$a"); done
  args+=("::$(archive_name "$name")" "${paths[@]}")

  info "Archiving '$name' (${#paths[@]} path(s)): ${paths[*]}"
  "$BORG_BIN" "${args[@]}" >>"$LOG" 2>&1
  local rc=$?

  case $rc in
    0) ARCHIVED=$((ARCHIVED+1)); info "Archived '$name'" ;;
    1) ARCHIVED=$((ARCHIVED+1)); warn "Archived '$name' with warnings (borg rc=1)" ;;
    *) FAILURES=$((FAILURES+1)); err "Failed to archive '$name' (borg rc=$rc)" ;;
  esac

  # Restart before pruning so the container is down for as little as possible.
  if [[ $was_running == 1 ]]; then restart_stopped; fi

  if [[ ${PRUNE_ENABLED:-yes} == yes && $DRY_RUN == 0 && $rc -le 1 ]]; then
    prune_container "$name"
  fi
}

prune_container() {
  local name=$1
  local glob rules=0
  if ! glob=$(archive_glob "$name"); then
    warn "Prune skipped for '$name': the archive format has no {container}, so a glob would match other containers' archives"
    return
  fi
  local -a args=(prune --lock-wait 120 "$MATCH_FLAG" "${MATCH_PREFIX}${glob}")
  [[ ${KEEP_DAILY:-0}   -gt 0 ]] && { args+=(--keep-daily   "$KEEP_DAILY");   rules=1; }
  [[ ${KEEP_WEEKLY:-0}  -gt 0 ]] && { args+=(--keep-weekly  "$KEEP_WEEKLY");  rules=1; }
  [[ ${KEEP_MONTHLY:-0} -gt 0 ]] && { args+=(--keep-monthly "$KEEP_MONTHLY"); rules=1; }
  [[ ${KEEP_YEARLY:-0}  -gt 0 ]] && { args+=(--keep-yearly  "$KEEP_YEARLY");  rules=1; }

  # With every rule at zero, prune would delete the archive we just made.
  if [[ $rules == 0 ]]; then
    warn "Prune skipped for '$name': no retention rules are set"
    return
  fi

  info "Pruning archives matching '$glob'"
  if ! "$BORG_BIN" "${args[@]}" >>"$LOG" 2>&1; then
    warn "Prune failed for '$name'"
  fi
}

CUR_NAME=""; CUR_STOP=0; CUR_ARGS=()
while IFS= read -r line; do
  case "$line" in
    "C "*) CUR_NAME=${line#C }; CUR_STOP=0; CUR_ARGS=() ;;
    "S "*) CUR_STOP=${line#S } ;;
    "P "*) CUR_ARGS+=("P${line#P }") ;;
    "X "*) CUR_ARGS+=("X${line#X }") ;;
    "E")
      if [[ -z $ONLY_CONTAINER || $ONLY_CONTAINER == "$CUR_NAME" ]]; then
        run_container "$CUR_NAME" "$CUR_STOP" "${CUR_ARGS[@]}"
      fi
      CUR_NAME=""
      ;;
  esac
done <"$PLAN"

if [[ ${COMPACT:-yes} == yes && $DRY_RUN == 0 && $ARCHIVED -gt 0 ]]; then
  info "Compacting repository"
  "$BORG_BIN" compact --lock-wait 120 >>"$LOG" 2>&1 || warn "Compact failed"
fi

if   [[ $FAILURES -gt 0 ]]; then finish failed;  exit 1
elif [[ $WARNINGS -gt 0 ]]; then finish warning; exit 0
else                             finish success; exit 0
fi

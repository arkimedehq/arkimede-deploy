# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright © 2026 Andrea Genovese

# backup-lib.sh — shared by scripts/backup.sh and scripts/restore-test.sh (sourced, not run).
#
# Destination abstraction: the backups go either to a host folder (HOST_BACKUP_DIR in .env,
# possibly a mounted NAS share) or to a network destination set from Settings → Backup
# (SMB / SFTP / WebDAV with user + password, encrypted in the DB). Host folders are written
# with plain shell; network destinations through an rclone container. Either way a backup
# is written under "<name>.part" and renamed only when complete.

# ── Paths, styling ────────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
STATE_DIR="$ROOT/backups/.state"     # local on purpose: must work while the destination is down
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=; G=; Y=; R=; C=; N=; fi
log()  { echo "$(date '+%F %T') $*"; }
step() { echo "${B}${C}▸ $*${N}"; }
ok()   { echo "  ${G}✓${N} $*"; }
warn() { echo "  ${Y}⚠${N} $*"; }
die()  { echo "${R}✗ $*${N}" >&2; exit 1; }

# `timeout` is missing on macOS: run without a bound there.
to() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }

command -v docker >/dev/null 2>&1 || die "docker not found"

# ── .env ──────────────────────────────────────────────────────────────────────
get_env() { grep -E "^$1=" "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" || true; }
DB_USER="$(get_env DB_USER)"; DB_USER="${DB_USER:-postgres}"
DB_NAME="$(get_env DB_NAME)"; DB_NAME="${DB_NAME:-arkimede}"
HOST_DATA_DIR="$(get_env HOST_DATA_DIR)"
HOST_BACKUP_DIR="$(get_env HOST_BACKUP_DIR)"; HOST_BACKUP_DIR="${HOST_BACKUP_DIR:-$ROOT/backups}"
HOST_BACKUP_REQUIRE_MOUNT="$(get_env HOST_BACKUP_REQUIRE_MOUNT)"
HOST_BACKUP_ALERT_WEBHOOK="$(get_env HOST_BACKUP_ALERT_WEBHOOK)"
HOST_BACKUP_WAL_SPOOL_MB="$(get_env HOST_BACKUP_WAL_SPOOL_MB)"; HOST_BACKUP_WAL_SPOOL_MB="${HOST_BACKUP_WAL_SPOOL_MB:-1024}"
HOST_BACKUP_WAL_TIMEOUT="$(get_env HOST_BACKUP_WAL_TIMEOUT)"; HOST_BACKUP_WAL_TIMEOUT="${HOST_BACKUP_WAL_TIMEOUT:-300}"
HOST_BACKUP_QDRANT="$(get_env HOST_BACKUP_QDRANT)"; HOST_BACKUP_QDRANT="${HOST_BACKUP_QDRANT:-on}"
RCLONE_IMAGE="$(get_env HOST_BACKUP_RCLONE_IMAGE)"; RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:1.68.2}"

# ── Compose chain: reuse the one install.sh chose, else the base file ─────────
if [[ -f scripts/.compose-profile ]]; then source scripts/.compose-profile
else COMPOSE_ARGS=(-f docker-compose.yml); fi
dc() { docker compose "${COMPOSE_ARGS[@]}" "$@"; }

PG_ID="$(dc ps -q postgres 2>/dev/null | head -1 || true)"
[[ -n "$PG_ID" ]] || die "postgres container is not running — start the stack first (./scripts/compose.sh up -d)"
PROJECT="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$PG_ID" 2>/dev/null || true)"
[[ -n "$PROJECT" ]] || PROJECT="$(basename "$ROOT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
PG_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$PG_ID")"
SPOOL_VOLUME="${PROJECT}_wal_spool"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

# ── Postgres helpers ──────────────────────────────────────────────────────────
# sql "<statement with :'var' placeholders>" var=value ... → unaligned rows on stdout.
sql() {
  local q="$1"; shift
  local vars=(-v ON_ERROR_STOP=1); for kv in "$@"; do vars+=(-v "$kv"); done
  printf '%s\n' "$q" | dc exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -qAtX "${vars[@]}"
}
# Same, but failures (e.g. table not migrated yet) are ignored: status writes are best-effort.
sql_try() { sql "$@" 2>/dev/null || true; }

# Settings from Settings → Backup (host_backup_config), defaults if the table is missing.
load_settings() {
  local row
  row="$(sql_try 'SELECT "keepDaily","keepBase","baseWeekday","walArchiving","destType","schedule" FROM host_backup_config WHERE id = 1')"
  IFS='|' read -r KEEP_DAILY KEEP_BASE BASE_WEEKDAY WAL_WANTED DEST_TYPE SCHEDULE <<<"$row"
  KEEP_DAILY="${KEEP_DAILY:-7}"; KEEP_BASE="${KEEP_BASE:-4}"; BASE_WEEKDAY="${BASE_WEEKDAY:-0}"
  [[ "$WAL_WANTED" == t ]] && WAL_WANTED=on || WAL_WANTED=off
  DEST_TYPE="${DEST_TYPE:-local}"
  SCHEDULE="${SCHEDULE:-15 2 * * *}"
}

# ── Schedule (cron expression, same grammar as backend/src/backup/backup-schedule.ts) ──
# cron_field_matches <value> <field> <min> <max>: items `*`, `n`, `a-b`, with an optional
# `/step`, comma-separated.
cron_field_matches() {
  local v=$1 min=$3 max=$4 item range step lo hi items
  IFS=, read -ra items <<<"$2"
  for item in "${items[@]}"; do
    step=1; range="$item"
    if [[ "$item" == */* ]]; then range="${item%/*}"; step="${item#*/}"; fi
    if [[ "$range" == '*' ]]; then lo=$min; hi=$max
    elif [[ "$range" == *-* ]]; then lo="${range%-*}"; hi="${range#*-}"
    else lo="$range"; hi="$range"; fi
    (( v >= lo && v <= hi && (v - lo) % step == 0 )) && return 0
  done
  return 1
}

# cron_matches "<min hour dom month dow>" → true if it fires in the current minute (host
# local time). As in cron, when both day fields are restricted either one matching is enough.
cron_matches() {
  local m h dom mon dow nm nh nd nmo nw day_ok
  read -r m h dom mon dow <<<"$1"
  read -r nm nh nd nmo nw <<<"$(date '+%M %H %d %m %w')"
  nm=$((10#$nm)); nh=$((10#$nh)); nd=$((10#$nd)); nmo=$((10#$nmo))
  cron_field_matches "$nm" "$m" 0 59 && cron_field_matches "$nh" "$h" 0 23 && cron_field_matches "$nmo" "$mon" 1 12 || return 1
  local dom_ok=1 dow_ok=1
  cron_field_matches "$nd" "$dom" 1 31 && dom_ok=0
  { cron_field_matches "$nw" "$dow" 0 7 || { (( nw == 0 )) && cron_field_matches 7 "$dow" 0 7; }; } && dow_ok=0
  if [[ "$dom" != '*' && "$dow" != '*' ]]; then (( dom_ok == 0 || dow_ok == 0 ))
  else (( dom_ok == 0 && dow_ok == 0 )); fi
}

# ── Alerts (webhook, deduplicated by condition) ───────────────────────────────
json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; printf '"%s"' "$s"; }

send_alert() {   # send_alert <subject> <message>
  local subject="$1" message="$2"
  log "ALERT: $message"
  sql_try "INSERT INTO host_backup_runs (kind, status, \"finishedAt\", message) VALUES ('alert', :'st', now(), :'msg')" \
    st="$subject" msg="$message" >/dev/null
  [[ -n "$HOST_BACKUP_ALERT_WEBHOOK" ]] || return 0
  curl -fsS -m 30 -H 'Content-Type: application/json' \
    -d "{\"host\":$(json_str "$HOSTNAME_SHORT"),\"kind\":\"backup\",\"subject\":$(json_str "$subject"),\"value\":\"\",\"message\":$(json_str "$message")}" \
    "$HOST_BACKUP_ALERT_WEBHOOK" >/dev/null 2>&1 || log "alert webhook failed"
}
# A condition alerts once when it starts and once when it clears.
alert_on()  { [[ -f "$STATE_DIR/alert-$1" ]] && return 0; send_alert "$2" "$3"; date > "$STATE_DIR/alert-$1"; }
alert_off() { [[ -f "$STATE_DIR/alert-$1" ]] || return 0; rm -f "$STATE_DIR/alert-$1"; send_alert "$2" "$3"; }

# ── Destination ───────────────────────────────────────────────────────────────
# dest_open sets DEST_MODE (local|remote), DEST_LABEL and, for remote, RC_ENV + RPATH.
# Fails (non-zero, DEST_ERROR set) when the destination is unmounted, unreachable or
# read-only — before anything is written.
DEST_MODE=; DEST_LABEL=; DEST_ERROR=; RC_ENV=; RPATH=

dest_close() { [[ -n "$RC_ENV" ]] && rm -f "$RC_ENV"; RC_ENV=; }

dest_open() {
  DEST_ERROR=
  if [[ "$DEST_TYPE" == local ]]; then
    DEST_MODE=local; DEST_LABEL="$HOST_BACKUP_DIR"
    if [[ -n "$HOST_BACKUP_REQUIRE_MOUNT" ]]; then
      # Touching the path triggers an automount; bounded, so a dead NAS cannot hang the job.
      if ! to 60 stat "$HOST_BACKUP_REQUIRE_MOUNT/." >/dev/null 2>&1; then
        DEST_ERROR="$HOST_BACKUP_REQUIRE_MOUNT is not reachable (network share down?)"; return 1
      fi
      if command -v findmnt >/dev/null 2>&1 && \
         ! findmnt -n -o FSTYPE --mountpoint "$HOST_BACKUP_REQUIRE_MOUNT" 2>/dev/null | grep -qv '^autofs$'; then
        DEST_ERROR="$HOST_BACKUP_REQUIRE_MOUNT is not mounted"; return 1
      fi
    fi
    if ! to 60 mkdir -p "$HOST_BACKUP_DIR" 2>/dev/null; then
      DEST_ERROR="cannot create $HOST_BACKUP_DIR"; return 1
    fi
    if ! to 60 bash -c 'echo ok > "$1/.write-probe" && rm -f "$1/.write-probe"' _ "$HOST_BACKUP_DIR" 2>/dev/null; then
      DEST_ERROR="$HOST_BACKUP_DIR is not writable (run as root? permissions of the share?)"; return 1
    fi
    return 0
  fi

  DEST_MODE=remote
  local raw pass
  raw="$(dc exec -T backend node dist/backup/host-backup-destination.cli.js 2>&1)" || {
    DEST_ERROR="cannot read the network destination from the backend (is it running?): ${raw:0:300}"; return 1; }
  RC_ENV="$(mktemp "$STATE_DIR/rclone-env.XXXXXX")"; chmod 600 "$RC_ENV"
  pass="$(grep '^RCLONE_DEST_PLAIN_PASS=' <<<"$raw" | cut -d= -f2-)"
  RPATH="$(grep '^RCLONE_DEST_PATH=' <<<"$raw" | cut -d= -f2-)"
  grep '^RCLONE_CONFIG_DEST_' <<<"$raw" > "$RC_ENV"
  # The password reaches rclone obscured, through a 0600 env-file (never on a command line).
  echo "RCLONE_CONFIG_DEST_PASS=$(printf '%s' "$pass" | docker run --rm -i "$RCLONE_IMAGE" obscure - 2>/dev/null)" >> "$RC_ENV"
  DEST_LABEL="$(sed -n 's/^RCLONE_CONFIG_DEST_TYPE=//p' "$RC_ENV")://$(sed -n -e 's/^RCLONE_CONFIG_DEST_HOST=//p' -e 's#^RCLONE_CONFIG_DEST_URL=.*//##p' "$RC_ENV")/${RPATH#/}"
  # mkdir + write + delete a probe, in one container (each one costs a start-up).
  local probe out; probe="$(rdest ".write-probe-$$")"
  if ! out="$(to 120 docker run --rm --env-file "$RC_ENV" --entrypoint sh "$RCLONE_IMAGE" -c \
      'rclone --config "" mkdir "$1" && rclone --config "" touch "$2" && rclone --config "" deletefile "$2"' _ "$(rdest)" "$probe" 2>&1)"; then
    DEST_ERROR="$DEST_LABEL is not reachable or not writable: $(tail -2 <<<"$out" | tr '\n' ' ')"; dest_close; return 1
  fi
}

# rclone in a throwaway container; extra docker args (mounts) before "--".
rc() {
  local dargs=(--rm)
  while [[ $# -gt 0 && "$1" != -- ]] && [[ "$1" == -v || "$1" == --volume ]]; do dargs+=("$1" "$2"); shift 2; done
  [[ "${1:-}" == -- ]] && shift
  to 3600 docker run --env-file "$RC_ENV" "${dargs[@]}" "$RCLONE_IMAGE" --config "" --retries 3 --low-level-retries 5 "$@"
}
rdest() { local p="${RPATH%/}"; [[ -n "${1:-}" ]] && p="${p:+$p/}$1"; echo "DEST:$p"; }

# dest_list <subdir> → entry names (dirs end with "/"), one per line.
dest_list() {
  if [[ "$DEST_MODE" == local ]]; then
    [[ -d "$HOST_BACKUP_DIR/$1" ]] || return 0
    (cd "$HOST_BACKUP_DIR/$1" && for f in *; do [[ -e "$f" ]] || continue; [[ -d "$f" ]] && echo "$f/" || echo "$f"; done)
  else
    rc lsf "$(rdest "$1")" 2>/dev/null || true
  fi
}

# dest_remove <relpath> (file or directory).
dest_remove() {
  if [[ "$DEST_MODE" == local ]]; then rm -rf "${HOST_BACKUP_DIR:?}/$1"
  elif [[ "$1" == */ ]]; then rc purge "$(rdest "${1%/}")"
  else rc deletefile "$(rdest "$1")"; fi
}

# Workspace for a backup named <subdir>/<name>: written in place on a local destination
# (as <name>.part), staged locally for a network one. dest_commit publishes it atomically.
work_begin() {
  WORK_SUB="$1"; WORK_NAME="$2"
  if [[ "$DEST_MODE" == local ]]; then
    WORK="$HOST_BACKUP_DIR/${WORK_SUB:+$WORK_SUB/}$WORK_NAME.part"
  else
    WORK="$STATE_DIR/staging/$WORK_NAME"
  fi
  rm -rf "$WORK"; mkdir -p "$WORK"; chmod 700 "$WORK"
}
work_commit() {
  local final="${WORK_SUB:+$WORK_SUB/}$WORK_NAME"
  if [[ "$DEST_MODE" == local ]]; then
    mv "$WORK" "$HOST_BACKUP_DIR/$final"
  else
    rc -v "$WORK:/src:ro" -- copy /src "$(rdest "$final.part")" \
      && rc moveto "$(rdest "$final.part")" "$(rdest "$final")" \
      || { rc purge "$(rdest "$final.part")" >/dev/null 2>&1 || true; return 1; }
    rm -rf "$WORK"
  fi
  WORK=; WORK_NAME=
}
work_abort() {
  [[ -n "${WORK:-}" ]] && rm -rf "$WORK"
  if [[ "$DEST_MODE" == remote && -n "${WORK_NAME:-}" ]]; then
    rc purge "$(rdest "${WORK_SUB:+$WORK_SUB/}$WORK_NAME.part")" >/dev/null 2>&1 || true
  fi
  WORK=
}

# dest_fetch <relpath-of-dir> <local dir> — copy a backup down (for restore tests).
dest_fetch() {
  if [[ "$DEST_MODE" == local ]]; then cp -a "$HOST_BACKUP_DIR/$1/." "$2/"
  else rc -v "$2:/dst" -- copy "$(rdest "$1")" /dst; fi
}

# Sorted list of committed backups (no .part) in <subdir> matching <prefix>.
dest_backups() { dest_list "$1" | awk -v p="$2" 'index($0, p) == 1 && /\/$/ && !/\.part\/$/ { sub(/\/$/, ""); print }' | sort; }

sha_check() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

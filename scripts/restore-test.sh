#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright © 2026 Andrea Genovese

# restore-test.sh — proves a backup restores, in a THROWAWAY container. Never touches the
# running stack: its own container (no network) and its own temporary volume, both removed
# at the end. Guide: docs/BACKUP.md (docs/BACKUP_it.md).
#
#   ./scripts/restore-test.sh snapshot [<arkimede-backup-…>]   snapshot (default newest):
#        checksums, archive integrity, db.sql.gz loaded into an empty Postgres, row counts
#   ./scripts/restore-test.sh pitr [--target "2026-11-02 14:30:00+01"] [--base <base-…>]
#        point-in-time recovery: newest base backup (before the target) + archived WAL,
#        replayed to the target (default: the end of the archive), row counts
#
# The backups are read from the configured destination (HOST_BACKUP_DIR or the network
# destination of Settings → Backup); a network one is copied to a temp folder first.
set -euo pipefail
source "$(dirname "$0")/backup-lib.sh"

MODE="${1:-snapshot}"; shift || true
TARGET=; PICK=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --base)   PICK="$2"; shift 2 ;;
    *)        PICK="$1"; shift ;;
  esac
done

TAG="arkimede-restore-test-$$"
TMP="$(mktemp -d "$STATE_DIR/restore.XXXXXX")"
cleanup() {
  docker rm -f "$TAG" >/dev/null 2>&1 || true
  docker volume rm "$TAG" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  dest_close
}
trap cleanup EXIT

load_settings
dest_open || die "backup destination unavailable: $DEST_ERROR"
echo "${B}Restore test${N} from ${DEST_LABEL} → throwaway container ${TAG} (no network)"

# Row counts of the main tables: what a restore is judged by.
report() {
  docker exec "$TAG" psql -U postgres -d "$DB_NAME" -qAtX -F '|' -c "
    SELECT 'tables', count(*)::text FROM information_schema.tables WHERE table_schema = 'public'
    UNION ALL SELECT 'users', count(*)::text FROM users
    UNION ALL SELECT 'chats', count(*)::text FROM chats
    UNION ALL SELECT 'messages', count(*)::text FROM messages
    UNION ALL SELECT 'files', count(*)::text FROM files
    UNION ALL SELECT 'newest message', max(\"createdAt\")::text FROM messages
    UNION ALL (SELECT 'last migration', name FROM migrations ORDER BY id DESC LIMIT 1)" |
  while IFS='|' read -r k v; do ok "$(printf '%-16s %s' "$k" "$v")"; done
}

wait_ready() {
  local i; for i in $(seq 1 "${1:-60}"); do
    docker exec "$TAG" pg_isready -U postgres >/dev/null 2>&1 && return 0
    docker inspect -f '{{.State.Running}}' "$TAG" 2>/dev/null | grep -q true || { docker logs --tail 30 "$TAG"; die "test Postgres stopped"; }
    sleep 1
  done
  docker logs --tail 30 "$TAG"; die "test Postgres not ready"
}

test_snapshot() {
  local name="$PICK"
  [[ -n "$name" ]] || name="$(dest_backups "" arkimede-backup- | tail -1)"
  [[ -n "$name" ]] || die "no snapshot found on $DEST_LABEL"
  step "Snapshot $name"
  if [[ "$DEST_MODE" == local ]]; then SRC="$HOST_BACKUP_DIR/$name"
  else SRC="$TMP/$name"; mkdir -p "$SRC"; dest_fetch "$name" "$SRC"; fi

  if [[ -f "$SRC/SHA256SUMS" ]]; then (cd "$SRC" && sha_check -c --quiet SHA256SUMS) && ok "checksums match"
  else warn "no SHA256SUMS (snapshot made by an older backup.sh)"; fi
  local f; for f in "$SRC"/*.tgz "$SRC"/*.gz; do
    [[ -e "$f" ]] || continue
    gzip -t "$f" && ok "$(basename "$f") readable ($(du -h "$f" | cut -f1))"
  done

  step "Load db.sql.gz into an empty Postgres ($PG_IMAGE)"
  docker run -d --name "$TAG" --network none -e POSTGRES_PASSWORD=restore-test -e POSTGRES_DB="$DB_NAME" \
    -v "$TAG:/var/lib/postgresql/data" "$PG_IMAGE" >/dev/null
  wait_ready
  sleep 2; wait_ready   # the image restarts once after its first init
  [[ -f "$SRC/globals.sql.gz" ]] && gunzip -c "$SRC/globals.sql.gz" | docker exec -i "$TAG" psql -U postgres -q >/dev/null 2>&1 || true
  gunzip -c "$SRC/db.sql.gz" | docker exec -i "$TAG" psql -U postgres -d "$DB_NAME" -q -v ON_ERROR_STOP=1 >/dev/null
  ok "dump loaded without errors"
  report
}

test_pitr() {
  local bases base
  bases="$(dest_backups wal/base base-)"
  [[ -n "$bases" ]] || die "no base backup on $DEST_LABEL (is WAL archiving on? backup.sh base)"
  if [[ -n "$PICK" ]]; then base="$PICK"
  elif [[ -n "$TARGET" ]]; then
    # Newest base backup started before the target (names are base-YYYYmmdd-HHMMSS, local time).
    local t
    if t="$(date -d "$TARGET" +%Y%m%d-%H%M%S 2>/dev/null)"; then
      base="$(awk -v t="base-$t" '$0 <= t' <<<"$bases" | tail -1)"
      [[ -n "$base" ]] || die "no base backup older than $TARGET"
    else   # no GNU date (macOS): Postgres still stops at the target, from the newest base
      base="$(tail -1 <<<"$bases")"; warn "cannot parse the target here: using the newest base backup (pass --base to choose)"
    fi
  else base="$(tail -1 <<<"$bases")"; fi
  step "Base backup $base${TARGET:+ → target $TARGET}"

  local bdir="$TMP/base" wdir="$TMP/wal"; mkdir -p "$bdir" "$wdir"
  dest_fetch "wal/base/$base" "$bdir"
  (cd "$bdir" && sha_check -c --quiet SHA256SUMS) && ok "base checksums match"
  local start; start="$(cat "$bdir/START_WAL")"
  # WAL from the base's start on (+ timeline history files).
  local need; need="$(dest_list wal/archive | awk -v s="${start:8:16}" '/history/ || (length($0) >= 24 && substr($0, 9, 16) >= s)')"
  printf '%s\n' "$need" > "$TMP/wal-list"
  if [[ "$DEST_MODE" == local ]]; then
    (cd "$HOST_BACKUP_DIR/wal/archive" && while read -r f; do [[ -n "$f" ]] && cp "$f" "$wdir/"; done < "$TMP/wal-list")
  else
    rc -v "$wdir:/dst" -v "$TMP/wal-list:/list:ro" -- copy --files-from /list "$(rdest wal/archive)" /dst
  fi
  ok "$(grep -c . "$TMP/wal-list" || true) archived WAL files from $start"

  # Unpack into the throwaway volume, owned by the image's postgres user.
  docker volume create "$TAG" >/dev/null
  docker run --rm -v "$TAG:/pgdata" -v "$bdir:/base:ro" -v "$wdir:/wal:ro" "$PG_IMAGE" bash -ec '
    tar -xzf /base/base.tar.gz -C /pgdata
    mkdir -p /pgdata/restore-wal && cp /wal/* /pgdata/restore-wal/ 2>/dev/null || true
    chown -R postgres:postgres /pgdata && chmod 700 /pgdata'
  # Later lines win over the archive settings captured in postgresql.auto.conf: the test
  # must never archive anywhere.
  local conf="archive_mode = off
archive_command = ''
restore_command = 'gunzip -c /var/lib/postgresql/data/restore-wal/%f.gz > %p'
recovery_target_action = 'promote'"
  [[ -n "$TARGET" ]] && conf+=$'\n'"recovery_target_time = '$TARGET'"
  docker run --rm -i -v "$TAG:/pgdata" "$PG_IMAGE" bash -ec \
    'cat >> /pgdata/postgresql.auto.conf; touch /pgdata/recovery.signal; chown postgres:postgres /pgdata/recovery.signal' <<<"$conf"

  step "Replay WAL in a throwaway Postgres ($PG_IMAGE)"
  docker run -d --name "$TAG" --network none -v "$TAG:/var/lib/postgresql/data" "$PG_IMAGE" >/dev/null
  wait_ready 300
  local i; for i in $(seq 1 300); do
    [[ "$(docker exec "$TAG" psql -U postgres -qAtX -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" == f ]] && break
    sleep 1
  done
  [[ "$(docker exec "$TAG" psql -U postgres -qAtX -c 'SELECT pg_is_in_recovery()')" == f ]] || { docker logs --tail 30 "$TAG"; die "recovery did not finish"; }
  docker logs "$TAG" 2>&1 | grep -E 'redo done|last completed transaction|recovery stopping|selected new timeline' | sed 's/^/    /'
  ok "recovered and promoted"
  report
}

case "$MODE" in
  snapshot) test_snapshot ;;
  pitr)     test_pitr ;;
  *)        die "usage: restore-test.sh snapshot [<name>] | pitr [--target <time>] [--base <base-…>]" ;;
esac
echo; echo "${B}${G}Restore test passed.${N} (the throwaway container and volume are removed)"

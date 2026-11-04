#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright © 2026 Andrea Genovese

# backup.sh — Arkimede's host-level backups. Guide: docs/BACKUP.md (docs/BACKUP_it.md).
#
#   ./scripts/backup.sh tick        every minute (cron): starts `run` when the schedule set in
#                                   Settings → Backup fires (cron expression), then `wal-ship`
#   ./scripts/backup.sh [run]       snapshot now (+ weekly Postgres base backup when WAL
#                                   archiving is on), then retention
#   ./scripts/backup.sh base        Postgres base backup now (needs WAL archiving on)
#   ./scripts/backup.sh wal-ship    every minute: apply the WAL-archiving switch, move the WAL
#                                   spool to the destination, raise/clear alerts
#   ./scripts/backup.sh status      destination, settings, last runs
#   ./scripts/backup.sh install-cron   (root) write /etc/cron.d/arkimede-backup
#
# A snapshot is  <dest>/arkimede-backup-<timestamp>/  containing:
#   db.sql.gz, globals.sql.gz — logical dump of the Arkimede database + roles
#   uploads.tgz, skills_data.tgz — user files and skills (the named volumes)
#   qdrant_data.tgz           — vectors (Qdrant paused while copied; regenerable by re-embed)
#   host-data.tgz             — HOST_DATA_DIR skills/state/skills-output/sandbox (broker profile)
#   config.tgz                — .env files and compose overlays: without TOOL_SECRETS_KEY the
#                               encrypted secrets in the dump cannot be read back
#   SHA256SUMS
# With WAL archiving on:  <dest>/wal/base/base-<timestamp>/  (weekly) + <dest>/wal/archive/.
#
# NOT backed up on purpose: redis (BullMQ queue/cache — transient), nix_store, the models.
# The destination is HOST_BACKUP_DIR (.env, default ./backups) or the network destination
# set in Settings → Backup. Written as "<name>.part" and renamed only when complete.
set -euo pipefail
source "$(dirname "$0")/backup-lib.sh"

CMD="${1:-run}"

# ── Locking: one run per kind ─────────────────────────────────────────────────
lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec {LOCK_FD}>"$STATE_DIR/lock-$1"
  flock -n "$LOCK_FD" || { [[ "${2:-}" == quiet ]] || log "another '$1' is running — skipped"; exit 0; }
}

# ── Run bookkeeping ───────────────────────────────────────────────────────────
RUN_ID=
run_begin() { RUN_ID="$(sql_try "INSERT INTO host_backup_runs (kind, status, location) VALUES (:'k', 'running', :'l') RETURNING id" k="$1" l="$2")"; }
run_end() {   # run_end <status> <bytes> <message>
  [[ -n "$RUN_ID" ]] || return 0
  sql_try "UPDATE host_backup_runs SET status = :'s', \"finishedAt\" = now(), \"sizeBytes\" = NULLIF(:'b', '')::bigint, message = NULLIF(:'m', '') WHERE id = :'id'" \
    s="$1" b="$2" m="$3" id="$RUN_ID" >/dev/null
  sql_try "DELETE FROM host_backup_runs WHERE \"startedAt\" < now() - interval '90 days'" >/dev/null
}
record_dest() {   # record_dest <reachable t|f>
  sql_try "UPDATE host_backup_config SET \"destReachable\" = :'r', \"destCheckedAt\" = now(), \"destResolved\" = :'l' WHERE id = 1" \
    r="$1" l="$DEST_LABEL" >/dev/null
}
dir_bytes() { du -sk "$1" | awk '{print $1 * 1024}'; }

# ── Volume / folder archives ──────────────────────────────────────────────────
tar_volume() {   # tar_volume <short volume name> <out file name>
  local vol="${PROJECT}_$1"
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then warn "volume $vol not found — skipped"; return 0; fi
  docker run --rm -v "$vol:/src:ro" -v "$WORK:/backup" alpine tar czf "/backup/$2" -C /src . || return 1
  ok "$2 ($(du -h "$WORK/$2" | cut -f1))"
}

snapshot() {
  local ts name; ts="$(date +%Y%m%d-%H%M%S)"; name="arkimede-backup-$ts"
  work_begin "" "$name"
  echo "${B}Backup → ${DEST_LABEL}/${name}${N}  (project: $PROJECT)"

  step "Postgres dump ($DB_NAME)"
  dc exec -T postgres pg_dump -U "$DB_USER" -d "$DB_NAME" | gzip > "$WORK/db.sql.gz"
  dc exec -T postgres pg_dumpall -U "$DB_USER" --globals-only | gzip > "$WORK/globals.sql.gz"
  ok "db.sql.gz ($(du -h "$WORK/db.sql.gz" | cut -f1))"

  step "Data volumes"
  tar_volume uploads uploads.tgz
  tar_volume skills_data skills_data.tgz
  if [[ "$HOST_BACKUP_QDRANT" == on ]] && dc ps -q qdrant 2>/dev/null | grep -q .; then
    # Paused while copied: a live tar of its storage would be an inconsistent copy.
    dc pause qdrant >/dev/null
    tar_volume qdrant_data qdrant_data.tgz || { dc unpause qdrant >/dev/null; return 1; }
    dc unpause qdrant >/dev/null
  fi

  if [[ -n "$HOST_DATA_DIR" && -d "$HOST_DATA_DIR" ]]; then
    step "Host data ($HOST_DATA_DIR)"
    local sub present=()
    for sub in skills state skills-output sandbox; do [[ -d "$HOST_DATA_DIR/$sub" ]] && present+=("$sub"); done
    if (( ${#present[@]} )); then
      tar czf "$WORK/host-data.tgz" -C "$HOST_DATA_DIR" "${present[@]}"
      ok "host-data.tgz: ${present[*]} ($(du -h "$WORK/host-data.tgz" | cut -f1))"
    fi
  fi

  step "Configuration"
  local cfg=()
  for f in .env .env.* frontend/.env scripts/.compose-profile docker-compose.*.yml; do
    [[ -f "$f" && "$f" != *.example ]] && cfg+=("$f")
  done
  tar czf "$WORK/config.tgz" "${cfg[@]}"
  chmod 600 "$WORK/config.tgz"
  ok "config.tgz: ${cfg[*]}"

  (cd "$WORK" && sha_check -- * > SHA256SUMS)
  SNAP_BYTES="$(dir_bytes "$WORK")"
  work_commit
  SNAP_NAME="$name"
}

prune_snapshots() {
  local all n; all="$(dest_backups "" arkimede-backup-)"
  n="$(grep -c . <<<"$all" || true)"
  (( n > KEEP_DAILY )) || return 0
  head -n $((n - KEEP_DAILY)) <<<"$all" | while read -r old; do
    dest_remove "$old/"; ok "removed old snapshot $old"
  done
}

# ── WAL archiving ─────────────────────────────────────────────────────────────
pg_setting() { sql "SELECT setting FROM pg_settings WHERE name = '$1'"; }

# Copies the archive script into the spool volume and makes it postgres-owned.
spool_prepare() {
  dc exec -T postgres test -d /wal-spool || die "postgres has no /wal-spool volume — update docker-compose.yml and recreate postgres (compose up -d postgres)"
  dc exec -T -u root postgres sh -c 'cat > /wal-spool/.archive.sh && chown -R postgres:postgres /wal-spool && chmod 700 /wal-spool' \
    < "$ROOT/scripts/pg-wal-archive.sh"
}

# Brings archive_mode to the switch in Settings → Backup. Changing archive_mode needs a
# Postgres restart (a few seconds); a failed attempt is not retried until the switch changes.
# Nothing is touched while the settings already match (this runs every minute).
wal_apply() {
  local mode cmd tmo want_cmd failed="$STATE_DIR/wal-apply-failed"
  want_cmd="sh /wal-spool/.archive.sh \"%p\" \"%f\" ${HOST_BACKUP_WAL_SPOOL_MB}"
  mode="$(pg_setting archive_mode)"; cmd="$(pg_setting archive_command)"; tmo="$(pg_setting archive_timeout)"
  if [[ "$WAL_WANTED" == on ]]; then
    [[ "$mode" == on && "$cmd" == "$want_cmd" && "$tmo" == "$HOST_BACKUP_WAL_TIMEOUT" ]] && { rm -f "$failed"; return 0; }
  else
    [[ "$mode" == off && -z "$cmd" ]] && { rm -f "$failed"; return 0; }
  fi
  [[ -f "$failed" && "$(cat "$failed")" == "$WAL_WANTED" ]] && return 0

  if [[ "$WAL_WANTED" == on ]]; then
    spool_prepare
    sql "ALTER SYSTEM SET archive_command = '$want_cmd'" >/dev/null
    sql "ALTER SYSTEM SET archive_timeout = '${HOST_BACKUP_WAL_TIMEOUT}s'" >/dev/null
    # New segments zero-filled, so the ones closed early by archive_timeout compress to little.
    sql "ALTER SYSTEM SET wal_recycle = off" >/dev/null
    sql "ALTER SYSTEM SET archive_mode = 'on'" >/dev/null
  else
    for s in archive_mode archive_command archive_timeout wal_recycle; do sql "ALTER SYSTEM RESET $s" >/dev/null; done
  fi
  if [[ "$mode" != "$WAL_WANTED" ]]; then
    log "WAL archiving $mode → $WAL_WANTED: restarting postgres"
    dc restart postgres >/dev/null
    local i; for i in $(seq 1 60); do dc exec -T postgres pg_isready -U "$DB_USER" >/dev/null 2>&1 && break; sleep 1; done
    mode="$(pg_setting archive_mode 2>/dev/null || echo '?')"
    if [[ "$mode" != "$WAL_WANTED" ]]; then
      echo "$WAL_WANTED" > "$failed"
      send_alert "WAL archiving" "Could not switch WAL archiving to $WAL_WANTED (archive_mode=$mode). Check the postgres logs."
      return 1
    fi
    send_alert "WAL archiving" "WAL archiving is now $WAL_WANTED."
  else
    sql "SELECT pg_reload_conf()" >/dev/null
  fi
  rm -f "$failed"
  sql_try "UPDATE host_backup_config SET \"walAppliedMode\" = :'m' WHERE id = 1" m="$mode" >/dev/null
}

# Base backup: tar of the whole cluster (also Recordare's database) with the WAL needed to
# make it consistent, so it restores even if the archive has a gap.
base_backup() {
  local ts name; ts="$(date +%Y%m%d-%H%M%S)"; name="base-$ts"
  work_begin wal/base "$name"
  step "Postgres base backup → ${DEST_LABEL}/wal/base/$name"
  dc exec -T postgres pg_basebackup -U "$DB_USER" -D - -Ft -X fetch -z --checkpoint=fast > "$WORK/base.tar.gz"
  local start; start="$(tar -xzOf "$WORK/base.tar.gz" backup_label | sed -n 's/^START WAL LOCATION: .*(file \([0-9A-F]*\)).*/\1/p')"
  [[ ${#start} -eq 24 ]] || die "base backup unreadable (no backup_label)"
  echo "$start" > "$WORK/START_WAL"
  (cd "$WORK" && sha_check -- base.tar.gz START_WAL > SHA256SUMS)
  BASE_BYTES="$(dir_bytes "$WORK")"
  work_commit
  ok "$name ($(( BASE_BYTES / 1024 / 1024 )) MB, from WAL $start)"
  prune_bases
}

# Keeps the newest KEEP_BASE base backups and the WAL archived since the oldest of them.
prune_bases() {
  local all n oldest start; all="$(dest_backups wal/base base-)"
  n="$(grep -c . <<<"$all" || true)"
  if (( n > KEEP_BASE )); then
    head -n $((n - KEEP_BASE)) <<<"$all" | while read -r old; do dest_remove "wal/base/$old/"; ok "removed old base backup $old"; done
  fi
  oldest="$(dest_backups wal/base base- | head -1)"
  [[ -n "$oldest" ]] || return 0
  if [[ "$DEST_MODE" == local ]]; then start="$(cat "$HOST_BACKUP_DIR/wal/base/$oldest/START_WAL")"
  else start="$(rc cat "$(rdest "wal/base/$oldest/START_WAL")")"; fi
  # Segment names sort by position after the 8-char timeline; *.history files are kept.
  local old_wal; old_wal="$(dest_list wal/archive | awk -v s="${start:8:16}" 'length($0) >= 24 && $0 !~ /history/ && substr($0, 9, 16) < s')"
  [[ -n "$old_wal" ]] || return 0
  if [[ "$DEST_MODE" == local ]]; then
    (cd "$HOST_BACKUP_DIR/wal/archive" && xargs rm -f <<<"$old_wal")
  else
    printf '%s\n' "$old_wal" > "$STATE_DIR/prune-list"
    rc -v "$STATE_DIR/prune-list:/list:ro" -- delete --files-from /list "$(rdest wal/archive)"
  fi
  ok "pruned $(grep -c . <<<"$old_wal") WAL segments older than $start"
}

newest_base_age_days() {
  local newest; newest="$(dest_backups wal/base base- | tail -1)"
  [[ -n "$newest" ]] || { echo 9999; return; }
  local d="${newest#base-}"; d="${d%%-*}"
  echo $(( ( $(date +%s) - $(date -d "$d" +%s 2>/dev/null || date -j -f %Y%m%d "$d" +%s) ) / 86400 ))
}

# Moves the spooled segments to <dest>/wal/archive. Prints the newest name shipped.
wal_ship_files() {
  local list="$1"
  if [[ "$DEST_MODE" == local ]]; then
    mkdir -p "$HOST_BACKUP_DIR/wal/archive"
    docker run --rm -v "$SPOOL_VOLUME:/spool" -v "$HOST_BACKUP_DIR/wal/archive:/dest" -v "$list:/list:ro" alpine sh -ec '
      while read -r f; do
        cp "/spool/$f" "/dest/.$f.tmp" && mv "/dest/.$f.tmp" "/dest/$f" && rm "/spool/$f"
      done < /list'
  else
    rc -v "$SPOOL_VOLUME:/spool" -v "$list:/list:ro" -- move --files-from /list /spool "$(rdest wal/archive)"
  fi
}

cmd_wal_ship() {
  lock wal-ship quiet
  load_settings
  wal_apply || exit 1
  [[ "$(pg_setting archive_mode)" == on ]] || exit 0

  # One look into the spool: size, gap marker, finished segments.
  local info spool_kb gap files
  info="$(dc exec -T postgres sh -c 'cd /wal-spool && du -sk . | cut -f1 && echo "gap:$(cat GAP 2>/dev/null)" && ls -1 | grep "\.gz$" | sort' 2>/dev/null)" || {
    alert_on spool "WAL archiving" "Cannot read the WAL spool in the postgres container."; exit 1; }
  spool_kb="$(sed -n 1p <<<"$info")"; gap="$(sed -n 's/^gap://p' <<<"$info")"; files="$(sed -n '3,$p' <<<"$info")"
  dc exec -T postgres test -f /wal-spool/.archive.sh || spool_prepare

  sql_try "UPDATE host_backup_config SET \"walSpoolBytes\" = :'b', \"walGapSegment\" = NULLIF(:'g', '') WHERE id = 1" \
    b=$((spool_kb * 1024)) g="$gap" >/dev/null
  local cap_kb=$((HOST_BACKUP_WAL_SPOOL_MB * 1024))
  if (( spool_kb * 2 >= cap_kb )); then
    alert_on spool-high "WAL archiving" "WAL spool at $((spool_kb / 1024)) MB of ${HOST_BACKUP_WAL_SPOOL_MB} MB: the backup destination is not receiving WAL. Past the limit WAL is dropped and point-in-time recovery has a gap until the next base backup."
  else
    alert_off spool-high "WAL archiving" "WAL spool back to normal ($((spool_kb / 1024)) MB)."
  fi
  if [[ -n "$gap" ]]; then
    alert_on gap "WAL archiving" "WAL archive gap from segment $gap (spool full). Point-in-time recovery is not possible past it until a new base backup — taken automatically when the destination is back."
  fi

  [[ -n "$files" || -n "$gap" ]] || exit 0
  if ! dest_open; then
    record_dest f
    alert_on dest "Backup destination" "Backup destination unavailable: $DEST_ERROR. WAL is held in the local spool."
    dest_close; exit 1
  fi
  trap dest_close EXIT
  record_dest t
  alert_off dest "Backup destination" "Backup destination reachable again ($DEST_LABEL)."

  if [[ -n "$files" ]]; then
    printf '%s\n' "$files" > "$STATE_DIR/ship-list"
    wal_ship_files "$STATE_DIR/ship-list"
    local last; last="$(tail -1 <<<"$files")"
    spool_kb="$(dc exec -T postgres du -sk /wal-spool | cut -f1)"
    sql_try "UPDATE host_backup_config SET \"walShippedAt\" = now(), \"walLastSegment\" = :'s', \"walSpoolBytes\" = :'b' WHERE id = 1" \
      s="${last%.gz}" b=$((spool_kb * 1024)) >/dev/null
  fi

  if [[ -n "$gap" ]]; then
    log "archive gap from $gap: taking a fresh base backup"
    # Own process: errexit does not apply inside an `if` condition.
    "$ROOT/scripts/backup.sh" base after-gap || log "base backup after the gap not done (exit $?) — retried next minute"
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────────
# The only cron entry: the schedule lives in the database, so changing it from the
# interface needs nothing on the host. The snapshot runs detached (it can take minutes).
cmd_tick() {
  load_settings
  if cron_matches "$SCHEDULE"; then
    log "schedule '$SCHEDULE' fired: snapshot started (backups/backup.log)"
    nohup "$ROOT/scripts/backup.sh" run >> "$ROOT/backups/backup.log" 2>&1 < /dev/null &
  fi
  cmd_wal_ship
}

cmd_run() {
  lock run
  load_settings
  log "backup start (dest: $DEST_TYPE, keep $KEEP_DAILY snapshots)"
  if ! dest_open; then
    record_dest f
    run_begin daily "$DEST_LABEL"; run_end failed "" "$DEST_ERROR"
    send_alert "Backup failed" "Snapshot NOT done: $DEST_ERROR"
    die "backup destination unavailable: $DEST_ERROR — nothing written"
  fi
  record_dest t
  trap 'rc_=$?; work_abort; dest_close; if (( rc_ )); then run_end failed "" "failed (exit $rc_), see backup.log"; send_alert "Backup failed" "Snapshot failed (exit $rc_) on $DEST_LABEL — see backups/backup.log"; fi' EXIT

  # Leftovers of an interrupted run (we hold the lock: nobody is writing them).
  dest_list "" | awk '/\.part\/$/' | while read -r p; do dest_remove "$p"; done
  dest_list wal/base | awk '/\.part\/$/' | while read -r p; do dest_remove "wal/base/$p"; done

  run_begin daily "$DEST_LABEL"
  snapshot
  run_end ok "$SNAP_BYTES" "$SNAP_NAME"
  prune_snapshots

  # Weekly base backup (or the first one, or overdue) while WAL archiving is on.
  if [[ "$WAL_WANTED" == on && "$(pg_setting archive_mode)" == on ]]; then
    local age; age="$(newest_base_age_days)"
    if [[ "$(date +%w)" == "$BASE_WEEKDAY" && $age -ge 1 ]] || (( age >= 7 )); then
      RUN_ID=; run_begin base "$DEST_LABEL/wal/base"
      base_backup
      run_end ok "$BASE_BYTES" "weekly"
    fi
  fi
  RUN_ID=
  echo; echo "${B}${G}Backup complete.${N}  ${C}$DEST_LABEL/$SNAP_NAME${N}"
}

cmd_base() {
  # Busy (a snapshot in progress) is a failure here, so `after-gap` is retried.
  if command -v flock >/dev/null 2>&1; then exec {LOCK_FD}>"$STATE_DIR/lock-run"; flock -n "$LOCK_FD" || exit 75; fi
  load_settings
  [[ "$(pg_setting archive_mode)" == on ]] || die "WAL archiving is off: a base backup alone adds nothing to the snapshot dump. Turn it on in Settings → Backup."
  dest_open || die "backup destination unavailable: $DEST_ERROR"
  trap 'rc_=$?; work_abort; dest_close; (( rc_ )) && run_end failed "" "failed (exit $rc_)"' EXIT
  run_begin base "$DEST_LABEL/wal/base"
  base_backup
  if [[ "${1:-}" == after-gap ]]; then
    dc exec -T postgres rm -f /wal-spool/GAP
    sql_try "UPDATE host_backup_config SET \"walGapSegment\" = NULL WHERE id = 1" >/dev/null
    run_end ok "$BASE_BYTES" "after a WAL archive gap"
    alert_off gap "WAL archiving" "New base backup taken after the WAL gap: point-in-time recovery available again from now."
  else
    run_end ok "$BASE_BYTES" "manual"
  fi
  RUN_ID=
}

cmd_status() {
  load_settings
  echo "${B}Settings${N}: schedule '$SCHEDULE', keep $KEEP_DAILY snapshots, $KEEP_BASE base backups, base on weekday $BASE_WEEKDAY, WAL archiving wanted: $WAL_WANTED (postgres: $(pg_setting archive_mode))"
  if dest_open; then
    echo "${B}Destination${N}: $DEST_LABEL ${G}(reachable)${N}"
    echo "${B}Snapshots${N}:";    dest_backups "" arkimede-backup- | sed 's/^/  /'
    echo "${B}Base backups${N}:"; dest_backups wal/base base- | sed 's/^/  /'
    echo "${B}WAL archive${N}: $(dest_list wal/archive | grep -c '\.gz$' || true) segments"
    dest_close
  else
    echo "${B}Destination${N}: ${R}$DEST_ERROR${N}"
  fi
  echo "${B}Recent runs${N}:"
  sql_try "SELECT to_char(\"startedAt\", 'YYYY-MM-DD HH24:MI'), kind, status, coalesce(message, '') FROM host_backup_runs ORDER BY \"startedAt\" DESC LIMIT 10" | sed 's/^/  /'
}

cmd_install_cron() {
  [[ $EUID -eq 0 ]] || die "run as root (the job writes the destination as root)"
  mkdir -p "$ROOT/backups"
  cat > /etc/cron.d/arkimede-backup <<EOF
# Arkimede host backups — written by scripts/backup.sh install-cron. Guide: docs/BACKUP.md
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Every minute: snapshot when the schedule of Settings → Backup fires, WAL shipping.
* * * * * root $ROOT/scripts/backup.sh tick >> $ROOT/backups/scheduler.log 2>&1
EOF
  chmod 644 /etc/cron.d/arkimede-backup
  ok "/etc/cron.d/arkimede-backup installed (schedule from Settings → Backup, WAL shipping every minute)"
}

case "$CMD" in
  run)          cmd_run ;;
  base)         cmd_base "${2:-}" ;;
  tick)         cmd_tick ;;
  wal-ship)     cmd_wal_ship ;;
  status)       cmd_status ;;
  install-cron) cmd_install_cron ;;
  -h|--help)    sed -n '5,29p' "$0" ;;
  *)            die "unknown command '$CMD' (tick | run | base | wal-ship | status | install-cron)" ;;
esac

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright © 2026 Andrea Genovese

# postgres-to-pgvector.sh — move an EXISTING install from `postgres:16-alpine` to
# `pgvector/pgvector:pg16` (the compose default since this change) safely.
#
# Why: the alpine image uses musl, pgvector's image is Debian/glibc. Same Postgres
# major (16) and same data path, so the data directory opens as is — but text
# collation (en_US.utf8, libc provider) sorts differently, so B-tree indexes on text
# columns built under musl may be wrong under glibc. They must be rebuilt, and each
# database's recorded collation version refreshed.
#
# What it does (idempotent — re-running on a migrated install does nothing):
#   1. backup first (./scripts/backup.sh: pg_dump + data volumes → backups/);
#   2. if postgres still runs the alpine image: recreate ONLY the postgres container
#      on the image the compose file now declares (data volume untouched) and wait
#      until it is ready;
#   3. for every database whose collation version does not match the C library
#      (datcollversion vs pg_database_collation_actual_version): REINDEX DATABASE,
#      then ALTER DATABASE … REFRESH COLLATION VERSION (or, when no version was ever
#      recorded — musl data dirs — the catalog's datcollversion set to the glibc one);
#   4. verify: amcheck bt_index_check on every B-tree index of user tables (the
#      amcheck extension is removed again if this script created it), then
#      re-check that no database is left with a mismatch.
#
# Fresh installs (data directory created by the pgvector image) need nothing.
# Run from the repo root, AFTER pulling the new docker-compose.yml, with the stack up:
#   ./scripts/postgres-to-pgvector.sh
# The REINDEX briefly blocks writes on the table being rebuilt: run it in a quiet moment.
set -euo pipefail
cd "$(dirname "$0")/.."

# ── Styling ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=; G=; Y=; R=; C=; N=; fi
step() { echo "${B}${C}▸ $*${N}"; }
ok()   { echo "  ${G}✓${N} $*"; }
warn() { echo "  ${Y}⚠${N} $*"; }
die()  { echo "  ${R}✗${N} $*" >&2; exit 1; }

# ── Compose chain: reuse the one install.sh chose, else the base file ─────────
if [[ -f scripts/.compose-profile ]]; then source scripts/.compose-profile
else COMPOSE_ARGS=(-f docker-compose.yml); fi
dc() { docker compose "${COMPOSE_ARGS[@]}" "$@"; }

command -v docker >/dev/null 2>&1 || die "docker not found"

get_env() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | xargs || true; }
DB_USER="$(get_env DB_USER)"; DB_USER="${DB_USER:-postgres}"

psql_db() { local db="$1"; shift; dc exec -T postgres psql -v ON_ERROR_STOP=1 -X -q -At -U "$DB_USER" -d "$db" "$@"; }

wait_ready() {
  for _ in $(seq 1 60); do
    dc exec -T postgres pg_isready -U "$DB_USER" >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "postgres did not become ready (./scripts/compose.sh logs postgres)"
}

# Databases (libc provider) whose recorded collation version differs from the C library's.
# On alpine both are NULL (musl reports no version) → nothing to do there.
# template0 (no connections) is excluded: initdb leaves its version unset even on a fresh
# glibc install, and databases created from it record their own version at CREATE DATABASE.
MISMATCH_SQL="SELECT datname FROM pg_database
               WHERE datlocprovider = 'c' AND datallowconn
                 AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)
               ORDER BY datname"

PG_ID="$(dc ps -q postgres 2>/dev/null | head -1 || true)"
[[ -n "$PG_ID" ]] || die "postgres container is not running — start the stack first (./scripts/compose.sh up -d)"

TARGET_IMAGE="$(dc config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["postgres"]["image"])' 2>/dev/null || true)"
[[ -n "$TARGET_IMAGE" ]] || TARGET_IMAGE="$(dc config 2>/dev/null | awk '/^  postgres:/{p=1} p&&/image:/{print $2; exit}')"
CURRENT_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$PG_ID")"
echo "${B}Postgres → pgvector${N}  current: ${C}$CURRENT_IMAGE${N}  compose: ${C}${TARGET_IMAGE:-?}${N}"

[[ "$TARGET_IMAGE" == pgvector/pgvector:* ]] \
  || die "the compose file does not declare a pgvector image for postgres (got '${TARGET_IMAGE:-?}') — update the repo first (git pull)"

BACKED_UP=0
backup() {
  [[ $BACKED_UP == 1 ]] && return 0
  step "Backup (scripts/backup.sh)"
  ./scripts/backup.sh
  BACKED_UP=1
}

# ── 1–2. Switch the container image if still on alpine ───────────────────────
if [[ "$CURRENT_IMAGE" != "$TARGET_IMAGE" ]]; then
  backup
  step "Recreating the postgres container on $TARGET_IMAGE (data volume kept)"
  dc pull postgres
  dc up -d --no-deps postgres
  wait_ready
  ok "postgres is up on $(docker inspect -f '{{.Config.Image}}' "$(dc ps -q postgres | head -1)")"
else
  ok "already on $TARGET_IMAGE"
fi

# ── 3. Rebuild indexes where the collation version does not match ─────────────
# (no mapfile: macOS still ships bash 3.2)
DBS=(); while IFS= read -r l; do [[ -n "$l" ]] && DBS+=("$l"); done < <(psql_db postgres -c "$MISMATCH_SQL")
if [[ ${#DBS[@]} -eq 0 ]]; then
  ok "every database's collation version matches the C library — nothing to do"
  exit 0
fi
backup
for db in "${DBS[@]}"; do
  step "REINDEX DATABASE \"$db\""
  psql_db "$db" -c "REINDEX DATABASE \"$db\";"
  ok "indexes rebuilt"
  # A data dir created under musl records NO version (NULL), and Postgres refuses
  # "REFRESH COLLATION VERSION" from NULL ("invalid collation version change"): set it
  # directly in the catalog then (superuser; it is the column REFRESH would update).
  if [[ "$(psql_db postgres -c "SELECT datcollversion IS NULL FROM pg_database WHERE datname = '$db'")" == "t" ]]; then
    psql_db postgres -c "UPDATE pg_database SET datcollversion = pg_database_collation_actual_version(oid) WHERE datname = '$db';" >/dev/null
  else
    psql_db postgres -c "ALTER DATABASE \"$db\" REFRESH COLLATION VERSION;" >/dev/null
  fi
  ok "collation version of \"$db\" recorded"
done

# ── 4. Verify ─────────────────────────────────────────────────────────────────
step "Verifying B-tree indexes (amcheck)"
for db in "${DBS[@]}"; do
  had="$(psql_db "$db" -c "SELECT count(*) FROM pg_extension WHERE extname = 'amcheck'")"
  if ! psql_db "$db" -c "CREATE EXTENSION IF NOT EXISTS amcheck;" >/dev/null 2>&1; then
    warn "$db: amcheck not available — the successful REINDEX is the check"
    continue
  fi
  n="$(psql_db "$db" -c "
    SELECT count(*) FROM (SELECT bt_index_check(i.indexrelid)
      FROM pg_index i
      JOIN pg_class c  ON c.oid = i.indexrelid
      JOIN pg_am a     ON a.oid = c.relam AND a.amname = 'btree'
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
       AND i.indisvalid AND i.indisready) checked")"
  [[ "$had" == "0" ]] && psql_db "$db" -c "DROP EXTENSION amcheck;" >/dev/null
  ok "$db: $n B-tree index(es) checked"
done
LEFT=(); while IFS= read -r l; do [[ -n "$l" ]] && LEFT+=("$l"); done < <(psql_db postgres -c "$MISMATCH_SQL")
[[ ${#LEFT[@]} -eq 0 ]] || die "collation version still mismatched for: ${LEFT[*]}"

echo
echo "${B}${G}Done.${N} Postgres runs on $TARGET_IMAGE with rebuilt indexes; backup in backups/."

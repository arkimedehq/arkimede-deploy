#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright © 2026 Andrea Genovese

# backup.sh — snapshot of Arkimede's persistent data.
#
# Produces  backups/arkimede-backup-<timestamp>/  containing:
#   db.sql.gz       — logical Postgres dump (pg_dump, gzip)
#   uploads.tgz     — user files / PDFs (the `uploads` volume)
#   skills_data.tgz — installed skills (the `skills_data` volume)
#   qdrant_data.tgz — vector store (the `qdrant_data` volume)
#
# NOT backed up on purpose: redis (BullMQ queue/cache — transient) and nix_store
# (regenerable). Postgres is dumped logically (consistent) rather than tarring its
# volume, which would be an inconsistent hot copy.
#
# Run from the repo root while the stack is up:  ./scripts/backup.sh
#
# Restore (rough): recreate the stack, then
#   gunzip -c db.sql.gz | ./scripts/compose.sh exec -T postgres psql -U <user> -d <db>
#   docker run --rm -v <project>_uploads:/dst -v "$PWD:/b" alpine \
#     sh -c 'cd /dst && tar xzf /b/uploads.tgz'
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ── Styling ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'; else B=; G=; Y=; C=; N=; fi
step() { echo "${B}${C}▸ $*${N}"; }
ok()   { echo "  ${G}✓${N} $*"; }
warn() { echo "  ${Y}⚠${N} $*"; }

# ── Compose chain: reuse the one install.sh chose, else the base file ─────────
if [[ -f scripts/.compose-profile ]]; then source scripts/.compose-profile
else COMPOSE_ARGS=(-f docker-compose.yml); fi
dc() { docker compose "${COMPOSE_ARGS[@]}" "$@"; }

command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 1; }

# ── DB credentials from .env (defaults match docker-compose.yml) ──────────────
get_env() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | xargs || true; }
DB_USER="$(get_env DB_USER)"; DB_USER="${DB_USER:-postgres}"
DB_NAME="$(get_env DB_NAME)"; DB_NAME="${DB_NAME:-arkimede}"

# ── Resolve the compose project name (volumes are <project>_<name>) ───────────
PG_ID="$(dc ps -q postgres 2>/dev/null | head -1 || true)"
[[ -n "$PG_ID" ]] || { echo "postgres container is not running — start the stack first (./scripts/compose.sh up -d)"; exit 1; }
PROJECT="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$PG_ID" 2>/dev/null || true)"
[[ -n "$PROJECT" ]] || PROJECT="$(basename "$ROOT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/backups/arkimede-backup-$TS"
mkdir -p "$OUT"

echo "${B}Backup → ${OUT}${N}  (project: $PROJECT)"

# ── 1. Postgres logical dump ──────────────────────────────────────────────────
step "Postgres dump ($DB_NAME)"
dc exec -T postgres pg_dump -U "$DB_USER" -d "$DB_NAME" | gzip > "$OUT/db.sql.gz"
ok "db.sql.gz ($(du -h "$OUT/db.sql.gz" | cut -f1))"

# ── 2. Data volumes (tar via a throwaway alpine mounting the volume) ──────────
for short in uploads skills_data qdrant_data; do
  vol="${PROJECT}_${short}"
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    step "Volume $vol"
    docker run --rm -v "$vol:/src:ro" -v "$OUT:/backup" alpine \
      tar czf "/backup/$short.tgz" -C /src . 2>/dev/null
    ok "$short.tgz ($(du -h "$OUT/$short.tgz" | cut -f1))"
  else
    warn "volume $vol not found — skipped"
  fi
done

echo
echo "${B}${G}Backup complete.${N}  ${C}$OUT${N}"
echo "  Contents: $(ls "$OUT" | tr '\n' ' ')"

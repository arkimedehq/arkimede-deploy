#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright © 2026 Andrea Genovese
#
# update-hub.sh — move a running PULL-based deployment to newer images, keeping data
# and config. The pull-based counterpart of the source repo's scripts/update.sh.
#
#   1. backup (scripts/backup.sh: pg_dump + data volumes → backups/), unless --no-backup;
#   2. `git pull --ff-only` of this bundle (new compose files / scripts), when it is a
#      git checkout;
#   3. flags new .env.example variables missing from your .env;
#   4. pulls the images of ARKIMEDE_VERSION (and the runner image for the broker levels);
#   5. `up -d` (recreates only the containers whose image changed);
#   6. scripts/postgres-to-pgvector.sh — idempotent; rebuilds text indexes once on
#      installs created with the old alpine Postgres image;
#   7. health check.
#
# Usage: ./update-hub.sh [--yes] [--no-backup]
# To move to a specific release, set ARKIMEDE_VERSION (and the -cuda / -light suffixed
# EMBEDDING_IMAGE_TAG / OCR_IMAGE_TAG) in .env first — or re-run ./install-hub.sh.
set -euo pipefail
cd "$(dirname "$0")"

B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
step() { echo; echo "${B}${C}▸ $*${N}"; }
ok()   { echo "  ${G}✓${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
die()  { echo "  ${R}✗ $*${N}" >&2; exit 1; }

YES=0; BACKUP=1
for a in "$@"; do
  case "$a" in
    --yes|-y)    YES=1 ;;
    --no-backup) BACKUP=0 ;;
    *) die "unknown option: $a" ;;
  esac
done

[[ -f .env ]] || die ".env not found — run ./install-hub.sh first"
# Installs made before the profile moved under scripts/ kept it at the root.
if [[ ! -f scripts/.compose-profile && -f .compose-profile ]]; then
  mkdir -p scripts && mv .compose-profile scripts/.compose-profile
fi
[[ -f scripts/.compose-profile ]] || die "scripts/.compose-profile not found — run ./install-hub.sh first"
source scripts/.compose-profile
dc() { docker compose "${COMPOSE_ARGS[@]}" "$@"; }

if (( ! YES )); then
  read -rp "  Update this deployment (backup → pull → restart)? [y/N] " r
  [[ "$r" =~ ^[yY] ]] || { warn "aborted"; exit 0; }
fi

step "1/7 · Backup"
if (( BACKUP )); then ./scripts/backup.sh; ok "backup done (backups/)"; else warn "skipped (--no-backup)"; fi

step "2/7 · Bundle files"
if [[ -d .git ]]; then
  git pull --ff-only && ok "bundle up to date"
  # The installer generates compose.sh from an older template on old installs: refresh it.
  sed -i.bak 's#^source \.compose-profile$#source scripts/.compose-profile#' compose.sh 2>/dev/null && rm -f compose.sh.bak || true
else
  warn "not a git checkout — fetch the new bundle files yourself"
fi

step "3/7 · New .env variables"
missing="$(comm -23 <(grep -oE '^[A-Z_]+=' .env.example | sort -u) <(grep -oE '^[A-Z_]+=' .env | sort -u) | tr -d '=' || true)"
if [[ -n "$missing" ]]; then
  warn "variables in .env.example not in your .env (their defaults apply; set them if needed):"
  echo "$missing" | sed 's/^/      /'
else
  ok "no new variables"
fi

step "4/7 · Pull images"
dc pull
set -a; . ./.env; set +a
if grep -q 'docker-compose.hub.broker.yml' scripts/.compose-profile; then
  RUNNER_IMG="${ARKIMEDE_IMAGE_PREFIX:-ghcr.io/arkimedehq/arkimede}-runner:${ARKIMEDE_VERSION:-latest}"
  docker pull "$RUNNER_IMG" >/dev/null && ok "runner image ready ($RUNNER_IMG)"
fi

step "5/7 · Restart"
dc up -d
ok "containers up"

step "6/7 · Postgres collation check"
./scripts/postgres-to-pgvector.sh || warn "postgres-to-pgvector.sh failed — the stack is up; re-run it by hand and check its output"

step "7/7 · Health check"
for _ in $(seq 1 40); do
  if curl -fsS http://localhost:3000/api/health >/dev/null 2>&1; then ok "backend healthy"; exit 0; fi
  sleep 3
done
die "backend not healthy after 2 minutes — check ./compose.sh logs backend"

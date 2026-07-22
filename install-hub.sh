#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright © 2026 Andrea Genovese

# install-hub.sh — guided installer for the PULL-based startup of Arkimede.
#
# Same guided flow as the source repo's scripts/install.sh, but it PULLS the pre-built
# images from the GitHub Container Registry instead of building from source. Nothing is
# compiled locally.
#
# Walks through: Docker preflight → secrets → SECURITY LEVEL → pull images → bootstrap
# dirs → `docker compose up`. Idempotent: re-running it is safe.
#
# Usage:
#   ./install-hub.sh [--dry-run]
set -euo pipefail

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) echo "Usage: $0 [--dry-run]  (--dry-run: shows the choices without writing/pulling/starting)"; exit 0 ;;
    *) echo "unknown argument: $a (use --help)"; exit 1 ;;
  esac
done

if [[ -t 1 ]]; then B=$'\e[1m'; DIM=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=; DIM=; G=; Y=; R=; C=; N=; fi
step() { echo; echo "${B}${C}▸ $*${N}"; }
ok()   { echo "  ${G}✓${N} $*"; }
warn() { echo "  ${Y}⚠${N} $*"; }
err()  { echo "  ${R}✗${N} $*" >&2; }
ask()  {
  local q="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then read -rp "  ${B}$q${N} [${def}]: " ans; echo "${ans:-$def}"
  else read -rp "  ${B}$q${N}: " ans; echo "$ans"; fi
}
yesno() {
  local q="$1" def="${2:-Y}" ans
  read -rp "  ${B}$q${N} [$([[ $def == Y ]] && echo 'Y/n' || echo 'y/N')]: " ans
  ans="${ans:-$def}"; [[ "$ans" =~ ^[YySsì]+$ ]]
}

cd "$(dirname "$0")"
ROOT="$(pwd)"
[[ -f docker-compose.hub.yml ]] || { err "docker-compose.hub.yml not found in $ROOT — run it from the bundle root."; exit 1; }
ENV_FILE="$ROOT/.env"

echo "${B}╭───────────────────────────────────────────────╮${N}"
echo "${B}│   Arkimede · pull-based installer (hub)   │${N}"
echo "${B}╰───────────────────────────────────────────────╯${N}"

# ── 1. Preflight ──────────────────────────────────────────────────────────────
step "1/6 · Preflight"
command -v docker >/dev/null 2>&1 || { err "docker not installed."; exit 1; }
docker compose version >/dev/null 2>&1 || { err "Docker Compose v2 ('docker compose') is required."; exit 1; }
docker info >/dev/null 2>&1 || { err "the Docker daemon is not responding — start Docker and retry."; exit 1; }
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) · compose v2 · daemon active"

GVISOR_OK=0
if docker info --format '{{range $r,$_ := .Runtimes}}{{$r}} {{end}}' 2>/dev/null | grep -qw runsc; then GVISOR_OK=1; ok "gVisor runtime (runsc) available"; fi

set_env() {
  local key="$1" val="$2"
  if (( DRY )); then echo "  ${DIM}[dry-run] .env: ${key}=${val}${N}"; return 0; fi
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    local esc; esc="$(printf '%s' "$val" | sed 's/[\\&|]/\\&/g')"
    sed -i.tmp "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE" && rm -f "$ENV_FILE.tmp"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}
get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | xargs || true; }
gen_secret() { openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# ── 2. .env + secrets ─────────────────────────────────────────────────────────
step "2/6 · Configuration and secrets (.env)"
(( DRY )) && warn "--dry-run mode: no writes to .env, no pull, no startup."
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ROOT/.env.example" ]]; then
    warn ".env missing: seeding it from .env.example (every variable with its documented default)."
    (( DRY )) || cp "$ROOT/.env.example" "$ENV_FILE"
  else
    warn ".env missing: creating a new one."
    (( DRY )) || : > "$ENV_FILE"
  fi
elif (( ! DRY )); then
  cp "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
  ok ".env backup created"
fi

# Image version to pull (default: latest). Pin a release tag for reproducibility.
cur_ver="$(get_env ARKIMEDE_VERSION)"
ark_ver="$(ask "Image version to pull (e.g. latest or 1.2.0)" "${cur_ver:-latest}")"
set_env ARKIMEDE_VERSION "$ark_ver"; ok "ARKIMEDE_VERSION=$ark_ver"

if yesno "PRODUCTION installation? (no = development)" "Y"; then
  IS_PROD=1; ok "production mode"
else
  IS_PROD=0; warn "development mode"
fi

weak() { local v; v="$(get_env "$1")"; [[ -z "$v" || "$v" == "password" || "$v" == "postgres" || "$v" == "changeme" || ${#v} -lt 16 ]]; }
for key in JWT_SECRET TOOL_SECRETS_KEY RUN_TOKEN_SECRET SERVICE_API_KEY; do
  if weak "$key"; then set_env "$key" "$(gen_secret)"; ok "$key generated (was missing/weak)";
  elif (( IS_PROD )) && yesno "Regenerate $key? (will invalidate in-progress tokens/sessions)" "N"; then
    set_env "$key" "$(gen_secret)"; ok "$key regenerated"
  else ok "$key kept"; fi
done

cur_up="$(get_env MAX_UPLOAD_MB)"
up_mb="$(ask "Max upload size in MB (file uploads via API/UI)" "${cur_up:-50}")"
if [[ "$up_mb" =~ ^[0-9]+$ ]] && (( up_mb > 0 )); then
  set_env MAX_UPLOAD_MB "$up_mb"; ok "MAX_UPLOAD_MB=${up_mb} MB"
else
  warn "invalid value \"$up_mb\": keeping ${cur_up:-50} MB"; set_env MAX_UPLOAD_MB "${cur_up:-50}"
fi

# Embedding device. With PULLED images this only SELECTS the image tag (cpu = default tag,
# cuda = the `-cuda` tag) — there is no local build. EMBEDDING_IMAGE_TAG combines the
# version with the optional -cuda suffix so docker-compose.hub.yml pulls the right variant.
cur_dev="$(get_env EMBEDDING_DEVICE)"
emb_dev="$(ask "Embedding device — cpu | cuda (cuda needs an NVIDIA GPU on this host)" "${cur_dev:-cpu}")"
case "$emb_dev" in
  cuda) set_env EMBEDDING_DEVICE cuda; set_env EMBEDDING_IMAGE_TAG "${ark_ver}-cuda"
        warn "EMBEDDING_DEVICE=cuda → pulling the -cuda image; make sure the GPU is visible to Docker" ;;
  cpu)  set_env EMBEDDING_DEVICE cpu;  set_env EMBEDDING_IMAGE_TAG "${ark_ver}"; ok "EMBEDDING_DEVICE=cpu (default image)" ;;
  *)    warn "invalid value \"$emb_dev\": using cpu"; set_env EMBEDDING_DEVICE cpu; set_env EMBEDDING_IMAGE_TAG "${ark_ver}" ;;
esac

if (( IS_PROD )); then
  if weak DB_PASSWORD; then
    if yesno "DB_PASSWORD is weak/missing: generate a strong one?" "Y"; then
      set_env DB_PASSWORD "$(gen_secret | cut -c1-32)"; ok "DB_PASSWORD generated"
    else warn "leaving DB_PASSWORD unchanged — postgres won't start in prod if empty"; fi
  else ok "DB_PASSWORD present"; fi

  cur_fe="$(get_env FRONTEND_URL)"
  fe_url="$(ask "Public frontend URL(s) for CORS (comma-separated)" "${cur_fe:-http://localhost:5173}")"
  set_env FRONTEND_URL "$fe_url"; ok "FRONTEND_URL set ($fe_url)"
fi

# ── 3. Security level ─────────────────────────────────────────────────────────
step "3/6 · Security level of skill/sandbox execution"
cat <<EOF
  Skills and the sandbox run code. Choose how much to isolate them:

    ${B}1) Standard${N}      ${DIM}— base compose. Skills run IN-PROCESS in the
                     skill-executor container (cap-drop ALL, no-new-priv, pids/mem
                     limits). Free egress. Lighter.${N}

    ${B}2) Isolated${N}      ${DIM}— + broker: every execution is an ephemeral, hardened
                     CONTAINER (read-only rootfs, non-root uid; jobs reach the backend
                     on arkimede-internal, no internet). Recommended.${N}

    ${B}3) Maximum${N}       ${DIM}— + egress allowlist: like Isolated, but network access
                     goes through a proxy that allows ONLY the allowlisted domains.
                     + optional gVisor.${N}
EOF
LEVEL="$(ask "Level [1/2/3]" "2")"
case "$LEVEL" in 1|2|3) ;; *) warn "invalid value, using 2"; LEVEL=2;; esac

PROJECT_NAME="arkimede"
COMPOSE_FILES=("-p" "$PROJECT_NAME" "-f" "docker-compose.hub.yml")
NEED_BROKER=0; NEED_EGRESS=0

if [[ "$LEVEL" == "1" ]]; then
  ok "Level 1 · Standard (in-process)"
  set_env BROKER_URL ""
  if yesno "Enable the sandbox tool (arbitrary code execution, NOT isolated in L1)?" "N"; then
    set_env SANDBOX_ALLOW_INPROCESS 1; warn "in-process sandbox active: code not confined, only if you trust the context"
  else
    set_env SANDBOX_ALLOW_INPROCESS 0; ok "sandbox disabled (fail-closed)"
  fi
else
  NEED_BROKER=1
  COMPOSE_FILES+=("-f" "docker-compose.hub.broker.yml")
  set_env SANDBOX_ALLOW_INPROCESS 0

  def_host="$(get_env HOST_DATA_DIR)"
  if [[ -z "$def_host" || "$def_host" != /* ]]; then
    case "$(uname -s)" in Darwin) def_host="$HOME/arkimede-data";; *) def_host="/srv/arkimede/data";; esac
  fi
  HOST_DATA_DIR="$(ask "Host path of the shared data (HOST_DATA_DIR)" "$def_host")"
  [[ "$HOST_DATA_DIR" == /* ]] || { err "HOST_DATA_DIR must be absolute."; exit 1; }
  set_env HOST_DATA_DIR "$HOST_DATA_DIR"

  if (( GVISOR_OK )) && yesno "Use gVisor (runsc) for even stronger kernel isolation?" "N"; then
    set_env BROKER_ALLOW_RUNSC 1; set_env JOB_RUNTIME runsc; ok "gVisor active for the jobs"
  else
    set_env BROKER_ALLOW_RUNSC 0; set_env JOB_RUNTIME runc
  fi

  echo
  echo "  ${DIM}The sandbox 'trusted' profile lets user code run as root on a writable rootfs${N}"
  echo "  ${DIM}(install system libraries at runtime). It weakens isolation — recommended only${N}"
  echo "  ${DIM}for a trusted single-tenant deploy or with gVisor enabled.${N}"
  if yesno "Allow the sandbox 'trusted' profile on this broker (BROKER_ALLOW_PRIVILEGED_SANDBOX)?" "N"; then
    set_env BROKER_ALLOW_PRIVILEGED_SANDBOX 1; warn "trusted sandbox profile ALLOWED — admins can enable it in the app"
  else
    set_env BROKER_ALLOW_PRIVILEGED_SANDBOX 0; ok "trusted sandbox profile disabled (broker forces hardened)"
  fi

  if [[ "$LEVEL" == "3" ]]; then
    NEED_EGRESS=1
    COMPOSE_FILES+=("-f" "docker-compose.hub.egress.yml")
    set_env BROKER_ALLOWED_NETWORKS "sandboxnet"
    set_env JOB_EGRESS_NETWORK "sandboxnet"
    ok "Level 3 · Maximum (broker + egress allowlist on 'sandboxnet')"
    warn "allowed domains are managed from the app (skill allowlist) → squid hot-reloads"
  else
    ok "Level 2 · Isolated (broker; jobs reach the backend on arkimede-internal, no internet)"
  fi
fi

# ── 4. Pull images ────────────────────────────────────────────────────────────
step "4/6 · Pull images"
if (( DRY )); then
  echo "  ${DIM}[dry-run] docker compose ${COMPOSE_FILES[*]} pull${N}"
  (( NEED_BROKER )) && echo "  ${DIM}[dry-run] docker pull <runner image> (launched by the broker via the socket)${N}"
else
  # `env -i`-free: source the .env only for the variables the compose files interpolate.
  set -a; # shellcheck disable=SC1090
  [[ -f "$ENV_FILE" ]] && . "$ENV_FILE"; set +a
  docker compose "${COMPOSE_FILES[@]}" pull
  ok "service images pulled"
  if (( NEED_BROKER )); then
    # The runner image is launched by the broker via the Docker socket (no long-running
    # service references it), so compose would not pull it — do it explicitly.
    RUNNER_IMG="${ARKIMEDE_IMAGE_PREFIX:-ghcr.io/arkimedehq/arkimede}-runner:${ARKIMEDE_VERSION:-latest}"
    echo "  pulling runner image ($RUNNER_IMG)…"; docker pull "$RUNNER_IMG" >/dev/null && ok "runner image ready"
  fi
fi

# ── 5. Bootstrap shared dirs (broker only) ────────────────────────────────────
step "5/6 · Filesystem preparation"
if (( NEED_BROKER )); then
  if (( DRY )); then echo "  ${DIM}[dry-run] HOST_DATA_DIR=$HOST_DATA_DIR bash bootstrap-broker.sh${N}"
  else HOST_DATA_DIR="$HOST_DATA_DIR" bash "$ROOT/bootstrap-broker.sh"; fi
else
  ok "no host dir to prepare (in-process execution)"
fi

# ── 6. Start the stack ────────────────────────────────────────────────────────
step "6/6 · Starting the containers"
echo "  ${DIM}docker compose ${COMPOSE_FILES[*]} up -d${N}"
if (( DRY )); then
  warn "[dry-run] startup not executed."
  echo; echo "${B}${Y}Dry-run completed (level $LEVEL). No changes applied.${N}"
  exit 0
elif yesno "Start the stack now?" "Y"; then
  docker compose "${COMPOSE_FILES[@]}" up -d
  echo
  docker compose "${COMPOSE_FILES[@]}" ps
else
  warn "startup skipped."
fi

# Persist the chosen profile for a compose wrapper.
{
  echo "# Generated by install-hub.sh — compose chain of the chosen profile (level $LEVEL)."
  printf 'COMPOSE_ARGS=('
  printf '%q ' "${COMPOSE_FILES[@]}"
  echo ')'
} > "$ROOT/.compose-profile"

cat > "$ROOT/compose.sh" <<'WRAP'
#!/usr/bin/env bash
# compose.sh — wrapper: uses the file chain chosen by the installer.
#   ./compose.sh logs -f backend
#   ./compose.sh down
set -euo pipefail
cd "$(dirname "$0")"
set -a; [[ -f .env ]] && . .env; set +a
source .compose-profile
exec docker compose "${COMPOSE_ARGS[@]}" "$@"
WRAP
chmod +x "$ROOT/compose.sh"

echo
echo "${B}${G}Installation completed (level $LEVEL).${N}"
echo "  Frontend:   ${C}http://localhost:5173${N}"
echo "  Management: ${C}./compose.sh ps | logs -f | down${N}"
(( LEVEL == 1 )) || echo "  Job data:   ${C}${HOST_DATA_DIR}${N}"

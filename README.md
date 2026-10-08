# Arkimede — deploy bundle (pull-based)

Slim bundle to run [**Arkimede**](https://github.com/arkimedehq/arkimede) by **pulling
pre-built images** from the GitHub Container Registry — no source checkout, no local build.

This repo contains only the deployment artifacts: compose files, the guided installer and
updater, `.env.example` and two maintenance scripts. The images live at
`ghcr.io/arkimedehq/arkimede-*`. The corresponding source code is at
[arkimedehq/arkimede](https://github.com/arkimedehq/arkimede) (AGPL-3.0).

> **Generated, not hand-edited.** Every release of the main repo regenerates this bundle
> from its compose files (`scripts/gen-deploy-bundle.py` there), so the pull-based and the
> source-based deployments always describe the same stack. Change things in the main repo.

> **Prefer to build from source instead?** Clone the [main repo](https://github.com/arkimedehq/arkimede)
> and run `./scripts/install.sh`. This bundle is the pull-and-run alternative.

## Requirements

- **Docker** + **Docker Compose v2** (`docker compose`). CPU-only by default (no GPU needed).
- **RAM:** ~3 GB idle with everything on (the embedding, speech and OCR models dominate),
  **8 GB** for real use. Small hosts: answer *no* to the voice services and pick the
  *light* OCR image in the installer.
- **Disk:** ~15 GB for images, models and the Nix store (~10 GB with the light OCR image).
- An LLM API key (Anthropic / OpenAI / Gemini / DeepSeek / …) — entered from the UI after
  startup, not here.

## Quick start

```bash
git clone https://github.com/arkimedehq/arkimede-deploy.git
cd arkimede-deploy
./install-hub.sh
```

The guided installer runs a Docker preflight, **generates all the secrets**, lets you pick
the image version, the embedding device (cpu/cuda), the OCR image (full/light), a
**security level** (Standard / Isolated / Maximum) and whether to run the voice services,
then **pulls** the images and starts the stack. It is idempotent — safe to re-run, e.g. to
change one of those choices. It then generates `./compose.sh` to manage the stack:

```bash
./compose.sh ps         # status
./compose.sh logs -f    # follow logs
./compose.sh down       # stop
```

Then open **http://localhost:5173** — the **first user to register becomes the admin**.
Configure LLM providers, embeddings and the vector DB from **Settings → AI System**.

## Upgrading

```bash
./update-hub.sh
```

It backs up the database and volumes (`backups/`), updates this bundle (`git pull`), lists
any new `.env` variables, pulls the images of `ARKIMEDE_VERSION`, restarts what changed,
runs the one-time Postgres check below and verifies the backend health. Flags: `--yes`,
`--no-backup`.

Pin `ARKIMEDE_VERSION` (and the matching `EMBEDDING_IMAGE_TAG` / `OCR_IMAGE_TAG`, see
below) to control exactly when you move; `latest` follows every release.

> **Installs created before October 2026** — two one-time points:
>
> - **Postgres image** moved from `postgres:16-alpine` to `pgvector/pgvector:pg16`. Same
>   data directory, different C library: text indexes must be rebuilt once.
>   `update-hub.sh` runs `scripts/postgres-to-pgvector.sh` for you (backup, `REINDEX`,
>   verification; it does nothing when not needed).
> - **Embedding default** moved from `mixedbread-ai/mxbai-embed-large-v1` to `BAAI/bge-m3`
>   (both 1024 dimensions, vectors not interchangeable). If your `.env` sets
>   `EMBEDDING_MODEL` (every `.env` seeded from `.env.example` does) nothing changes.
>   Otherwise add `EMBEDDING_MODEL=mixedbread-ai/mxbai-embed-large-v1`, or keep bge-m3 and
>   run the admin re-embed (`GET /api/admin/vector-db/reembed/plan`, then
>   `POST /api/admin/vector-db/reembed`).

## Manual start (without the installer)

```bash
cp .env.example .env
# Set at least: DB_PASSWORD, JWT_SECRET, TOOL_SECRETS_KEY, RUN_TOKEN_SECRET, SERVICE_API_KEY
#   (generate each with: openssl rand -hex 32)

# Standard (in-process skill execution):
docker compose -p arkimede -f docker-compose.hub.yml up -d

# Isolated (container-per-job broker) — set HOST_DATA_DIR in .env first, then:
HOST_DATA_DIR=/srv/arkimede/data ./bootstrap-broker.sh
docker pull ghcr.io/arkimedehq/arkimede-runner:latest     # launched by the broker, not by compose
docker compose -p arkimede -f docker-compose.hub.yml -f docker-compose.hub.broker.yml up -d

# Maximum (broker + egress allowlist):
docker compose -p arkimede -f docker-compose.hub.yml \
  -f docker-compose.hub.broker.yml -f docker-compose.hub.egress.yml up -d

# Any level without the voice services (Whisper + Piper): add
#   -f docker-compose.hub.novoice.yml
```

For `./update-hub.sh` and the maintenance scripts, record the chain you use in
`scripts/.compose-profile`, e.g.:

```bash
echo 'COMPOSE_ARGS=(-p arkimede -f docker-compose.hub.yml -f docker-compose.hub.broker.yml)' > scripts/.compose-profile
```

## Configuration knobs

Everything is set in `.env` (see `.env.example` for the full, documented list). The ones
specific to this bundle:

| Variable | Default | What it does |
|---|---|---|
| `ARKIMEDE_VERSION` | `latest` | Image tag to pull. Pin a release (e.g. `0.2.0`) for reproducibility. |
| `ARKIMEDE_IMAGE_PREFIX` | `ghcr.io/arkimedehq/arkimede` | Registry/image prefix — change for a fork or mirror. |
| `EMBEDDING_DEVICE` / `EMBEDDING_IMAGE_TAG` | `cpu` / `latest` | `cuda` + `<version>-cuda` select the CUDA image (needs an NVIDIA GPU visible to Docker). |
| `OCR_IMAGE_TAG` | `latest` | `<version>` = full OCR image (Docling, ~4 GB); `<version>-light` = Tesseract only (~0.5 GB). |
| `HOST_DATA_DIR` | — | **Required for Isolated/Maximum.** Absolute host path for the broker's shared job folders (bind-mounted). |
| `DB_PASSWORD`, `JWT_SECRET`, `TOOL_SECRETS_KEY`, `RUN_TOKEN_SECRET`, `SERVICE_API_KEY` | — | Mandatory secrets (the backend fails fast without them). |
| `MAX_UPLOAD_MB` | `50` | Upload cap (nginx + backend). |

The images carry the default models (embedding `BAAI/bge-m3`, Whisper `small`, Piper
`it_IT-serena-medium`). Setting another `EMBEDDING_MODEL` / `WHISPER_MODEL` / `PIPER_VOICE`
works too: the model is downloaded on first start instead of using the baked copy.

## Terminal client (optional)

The stack you just deployed is fully usable from the browser. If you also
want to chat from the shell, the `arkimede` CLI is a separate npm package
(it is not part of the Docker images):

```bash
npm install -g @arkimedehq/arkimede-cli
arkimede login --url http://localhost:3000
arkimede    # full-screen TUI
```

Reference: [CLI.md](https://github.com/arkimedehq/arkimede/blob/main/docs/CLI.md).

## License

The deployment artifacts in this repo are **AGPL-3.0** (see `LICENSE`), like the rest of
Arkimede. Corresponding source: https://github.com/arkimedehq/arkimede

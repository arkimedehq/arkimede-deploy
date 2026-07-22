# Arkimede — deploy bundle (pull-based)

Slim bundle to run [**Arkimede**](https://github.com/arkimedehq/arkimede) by **pulling
pre-built images** from the GitHub Container Registry — no source checkout, no local build.

This repo contains only the deployment artifacts (a few KB): compose files, the guided
installer, `.env.example`. The images live at `ghcr.io/arkimedehq/arkimede-*`. The
corresponding source code is at [arkimedehq/arkimede](https://github.com/arkimedehq/arkimede)
(AGPL-3.0).

> **Prefer to build from source instead?** Clone the [main repo](https://github.com/arkimedehq/arkimede)
> and run `./scripts/install.sh`. This bundle is the pull-and-run alternative.

## Requirements

- **Docker** + **Docker Compose v2** (`docker compose`). CPU-only by default (no GPU needed).
- **~2 GB RAM** idle (the embedding + Whisper models dominate), **4 GB** a comfortable
  minimum, 8 GB for real use. **~10 GB disk** for images, models and the Nix store.
- An LLM API key (Anthropic / OpenAI / Gemini / …) — entered from the UI after startup, not here.

## Quick start

```bash
git clone https://github.com/arkimedehq/arkimede-deploy.git
cd arkimede-deploy
./install-hub.sh
```

The guided installer runs a Docker preflight, **generates all the secrets**, lets you pick
the image version, the embedding device (cpu/cuda) and a **security level**
(Standard / Isolated / Maximum), **pulls** the images and starts the stack. It is
idempotent — safe to re-run. It then generates `./compose.sh` to manage the stack:

```bash
./compose.sh ps         # status
./compose.sh logs -f    # follow logs
./compose.sh down       # stop
```

Then open **http://localhost:5173** — the **first user to register becomes the admin**.
Configure LLM providers, embeddings and the vector DB from **Settings → AI System**.

## Manual start (without the installer)

```bash
cp .env.example .env
# Set at least: DB_PASSWORD, JWT_SECRET, TOOL_SECRETS_KEY, RUN_TOKEN_SECRET, SERVICE_API_KEY
#   (generate each with: openssl rand -hex 32)

# Standard (in-process skill execution):
docker compose -p arkimede -f docker-compose.hub.yml up -d

# Isolated (container-per-job broker) — set HOST_DATA_DIR in .env first, then:
HOST_DATA_DIR=/srv/arkimede/data ./bootstrap-broker.sh
docker compose -p arkimede -f docker-compose.hub.yml -f docker-compose.hub.broker.yml up -d

# Maximum (broker + egress allowlist):
docker compose -p arkimede -f docker-compose.hub.yml \
  -f docker-compose.hub.broker.yml -f docker-compose.hub.egress.yml up -d
```

## Configuration knobs

Everything is set in `.env`. The ones that matter most:

| Variable | Default | What it does |
|---|---|---|
| `ARKIMEDE_VERSION` | `latest` | Image tag to pull. Pin a release (e.g. `1.2.0`) for reproducibility. |
| `ARKIMEDE_IMAGE_PREFIX` | `ghcr.io/arkimedehq/arkimede` | Registry/image prefix — change for a fork or mirror. |
| `EMBEDDING_DEVICE` / `EMBEDDING_IMAGE_TAG` | `cpu` / `latest` | `cuda` selects the `-cuda` image (needs an NVIDIA GPU visible to Docker). |
| `HOST_DATA_DIR` | — | **Required for Isolated/Maximum.** Absolute host path for the broker's shared job folders (bind-mounted). |
| `DB_PASSWORD`, `JWT_SECRET`, `TOOL_SECRETS_KEY`, `RUN_TOKEN_SECRET`, `SERVICE_API_KEY` | — | Mandatory secrets (the backend fails fast without them). |
| `MAX_UPLOAD_MB` | `50` | Upload cap (nginx + backend). |

## Upgrading

```bash
# Pull newer images and restart, keeping data and config:
./compose.sh pull && ./compose.sh up -d
```

Pin `ARKIMEDE_VERSION` to a specific tag to control exactly when you move.

## License

The deployment artifacts in this repo are **AGPL-3.0** (see `LICENSE`), like the rest of
Arkimede. Corresponding source: https://github.com/arkimedehq/arkimede

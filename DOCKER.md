# SparkByte Docker & ops

## Quick start

1. Copy env template: **`cp .env.example .env`** (or copy on Windows) and add API keys you use.
2. **Compose:** `docker compose up --build`
3. **Smoke test** (host, with stack running): `powershell -File scripts/smoke_endpoints.ps1`

| Surface | URL |
|--------|-----|
| SparkByte UI / WebSocket | `http://localhost:${SPARKBYTE_PUBLIC_PORT:-8081}` |
| SparkByte health | `GET http://localhost:8081/health` |
| **A2A public routes on SparkByte port** | `GET http://localhost:8081/.well-known/agent.json` and `POST http://localhost:8081/` |
| Public A2A health | `GET http://localhost:8081/a2a/health` |
| **A2A sidecar** (optional direct port) | `http://localhost:${A2A_PUBLIC_PORT:-8082}` |
| A2A health | `GET http://localhost:8082/health` |
| Agent card | `GET http://localhost:8082/.well-known/agent.json` |

## Build

```bash
docker build -t sparkbyte .
```

## Run (single container)

```bash
docker run --rm -it -p 8081:8081 -p 8082:8082 --env-file .env \
  -e SPARKBYTE_STATE_DIR=/app/runtime \
  -v sparkbyte-state:/app/runtime \
  sparkbyte
```

- Map **both** ports if you use **A2A** (`8082` inside the image).
- Browser auto-launch is disabled in Docker; the app still starts **headless Chromium** for `browse_url` where configured.

### Host Ollama

```bash
docker run --rm -it -p 8081:8081 -p 8082:8082 --env-file .env \
  --add-host=host.docker.internal:host-gateway \
  -e SPARKBYTE_STATE_DIR=/app/runtime \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  -v sparkbyte-state:/app/runtime \
  sparkbyte
```

## Compose

```bash
docker compose up --build
```

`compose.yaml` loads `.env`, maps **8081** (SparkByte) and **8082** (A2A sidecar), and persists state in volume `sparkbyte-state` → `/app/runtime`.

## A2A (production notes)

- Set **`A2A_API_KEY`** in `.env` if you want one bootstrap owner key; add **`A2A_ADMIN_KEY`** for billing/admin methods.
- Set **`A2A_BILLING_ENFORCE=1`** to require active entitlement before `tasks/send` runs.
- Set **`A2A_BILLING_PAYMENT_LINK_URL`** and **`A2A_BILLING_PORTAL_URL`** for fast launch checkout/portal links, or wire your own payment flow and use `billing/link` to activate accounts.
- Set **`A2A_PUBLIC_URL`** to the **external** base URL (e.g. `https://agent.example.com`) so `/.well-known/agent.json` advertises the correct endpoint behind a reverse proxy.
- Public routes now ride the SparkByte port too:
  - **`GET /.well-known/agent.json`**
  - **`GET /a2a/health`**
  - **`POST /`** or **`POST /a2a`** for JSON-RPC methods such as `tasks/send`, `tasks/get`, `tasks/list`, and `tasks/cancel`
- Monetization RPCs ride the same JSON-RPC lane:
  - `billing/key/create`
  - `billing/status`
  - `usage/get`
  - `billing/checkout`
  - `billing/portal`
  - `billing/link`
- The sidecar on **`8082`** still exposes the original direct A2A surface for local ops and debugging.

## Julian bridge (optional)

If **`JulianMetaMorph/JulianMetaMorph`** exists in the repo (copied into the image), SparkByte sets **`JULIAN_ROOT`** / **`JULIAN_DB`** at boot when unset. **Julian's autonomous curiosity loop runs by default** (every **3600s / 1 hour**). Override with **`JULIAN_AUTONOMOUS_SECONDS`**; set **`-1`** to explicitly disable.

- **`GITHUB_TOKEN`** in `.env` improves GitHub rate limits for Julian hunts.
- **MCP** (`mcp_server/server.py`): defaults **`JULIAN_DB`** to `JulianMetaMorph/JulianMetaMorph/data/quarry.db` under the project root unless **`JULIAN_DB`** is set.

## Environment reference

See **`.env.example`** for all variables (SparkByte, A2A, Julian, LLM keys, Ollama).

## Notes

- Multi-stage **Dockerfile** caches Julia precompile; runtime exposes **8081** and **8082**.
- `run_command` uses PowerShell on Windows and POSIX shell on Linux (including the container).
- Runtime state: **`SPARKBYTE_STATE_DIR`** (default `/app/runtime` in Compose) holds SQLite, telemetry, forged tools, etc.

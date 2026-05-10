# JL Engine / SparkByte Omni Deployment Runbook

This repo ships a long-running Julia application, not a static-only web app.
Use Docker Compose or a container host/VM that can keep ports `8081` and `8082`
open. The optional `web/` Next.js app is a separate cinematic landing surface;
it is not the SparkByte runtime.

## Stack and entrypoints

| Surface | Stack | Entrypoint | Default port |
|---|---|---|---|
| SparkByte UI + WebSocket | Julia + HTTP.jl + BYTE | `julia --project=. sparkbyte.jl` | `8081` |
| A2A API | Julia + HTTP.jl + SQLite | started by `src/App.jl` / `a2a_server.jl` | `8082` |
| Julian MetaMorph bridge | Python + FastAPI | managed by SparkByte or `python -m julian_metamorph.cli serve` | `8765` |
| Landing surface | Next.js | `cd web && npm run build && npm run start` | `3000` |
| Docker runtime | `julia:1.12.1` + Python deps | `docker compose up --build` | `8081`, `8082` |

## Required tools

- Julia `1.12.x` for local non-Docker runs.
- Python `3.10+` for Julian MetaMorph and SparkByte browser tooling.
- Node `20+` for the optional Next.js landing surface.
- Docker + Docker Compose for the recommended production path.

Use these dependency entrypoints, not the legacy root `requirements.txt` snapshot:

- Julia runtime: `julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'`
- SparkByte browser/runtime Python deps: `python -m pip install -r requirements.docker.txt`
- Julian MetaMorph: `python -m pip install -e JulianMetaMorph/JulianMetaMorph`
- MCP bridge: `python -m pip install -r mcp_server/requirements.txt`
- Next.js landing surface: `cd web && npm ci`

## Environment setup

```bash
cp .env.example .env
```

Set these before any public deployment:

```bash
SPARKBYTE_HOST=0.0.0.0
SPARKBYTE_PORT=8081
SPARKBYTE_LAUNCH_BROWSER=0
A2A_HOST=0.0.0.0
A2A_PORT=8082
A2A_PUBLIC_URL=https://YOUR-A2A-HOST.example.com
A2A_API_KEY=replace-with-a-long-random-token
A2A_ADMIN_KEY=replace-with-a-different-long-random-token
```

Optional LLM/tool keys stay in `.env` or the cloud secret store. Do not commit
real values. `.env`, SQLite databases, logs, runtime generated tools, and local
Next.js build artifacts are gitignored.

## Local deployment sequence

### Linux / macOS

```bash
cp .env.example .env
python -m pip install -e JulianMetaMorph/JulianMetaMorph
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
SPARKBYTE_LAUNCH_BROWSER=0 JULIAN_AUTONOMOUS_SECONDS=-1 julia --project=. sparkbyte.jl
```

In another shell:

```bash
scripts/smoke_endpoints.sh
```

### Windows PowerShell

```powershell
Copy-Item .env.example .env
python -m pip install -e JulianMetaMorph/JulianMetaMorph
julia --project=. -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
$env:SPARKBYTE_LAUNCH_BROWSER = "0"
$env:JULIAN_AUTONOMOUS_SECONDS = "-1"
julia --project=. sparkbyte.jl
```

In another PowerShell:

```powershell
powershell -File scripts/smoke_endpoints.ps1
```

## Docker Compose production path

```bash
cp .env.example .env
# edit .env: set A2A_PUBLIC_URL, A2A_API_KEY, A2A_ADMIN_KEY, and any LLM keys
docker compose up --build -d
docker compose ps
scripts/smoke_endpoints.sh
```

Expected smoke result:

```text
[smoke] SparkByte health: http://127.0.0.1:8081/health
[smoke] A2A health: http://127.0.0.1:8082/health
[smoke] A2A agent card: http://127.0.0.1:8082/.well-known/agent.json
[smoke] OK
```

## Optional Next.js landing surface

```bash
cd web
npm ci
npm run lint
npm run typecheck
npm run build
npm run start -- --hostname 0.0.0.0 --port 3000
```

## Health endpoints

- SparkByte: `GET /health` on port `8081`.
- A2A: `GET /health` and `GET /.well-known/agent.json` on port `8082`.
- Public A2A passthrough on SparkByte port: `GET /a2a/health`.

## Database and state

There is no separate migration command. SparkByte creates and upgrades its SQLite
tables at startup via `_open_memory_db` and `_a2a_init_db!`. Persist
`SPARKBYTE_STATE_DIR` in production; Compose mounts the `sparkbyte-state` volume
to `/app/runtime`.

## Cloud deploy assumptions

- Use a Linux container host, VM, Azure Container Apps, or similar long-running
  service. Vercel-style static/serverless hosting is only appropriate for the
  optional `web/` landing surface.
- Terminate TLS at the platform load balancer/reverse proxy.
- Route external traffic to `8081` for SparkByte UI/WebSocket and `8082` for A2A,
  or explicitly proxy `/a2a/*` to the SparkByte public passthrough.
- Set `A2A_PUBLIC_URL` to the public HTTPS base URL clients should discover.
- Store `.env` values in the platform secret manager; do not bake secrets into
  images.

## Rollback / undo

```bash
docker compose down
# then redeploy the previous image/tag or previous Git revision
docker compose up -d
```

For local runs, stop the Julia process with `Ctrl+C`. Runtime state is under
`SPARKBYTE_STATE_DIR` (or the repo root by default); back it up before deleting.

## Current verified gates from this cleanup

- Julia dependencies instantiate/precompile on Julia `1.12.1`.
- Julia test suite passes: `88` pass, `1` broken/expected-broken test.
- SparkByte and A2A start locally and pass `scripts/smoke_endpoints.sh`.
- Next.js landing lint/typecheck/build/start were verified on Node `20.20.2`.
- `npm audit --audit-level=high` passes for `web/`; npm still reports moderate
  Next.js/PostCSS advisories with no non-breaking fix available from the current
  latest `next@16.2.6`.
- Julian MetaMorph tests pass after adding the missing `httpx` runtime dependency.
- Docker is configured but could not be executed in the cleanup runner because the
  runner does not have the Docker CLI installed. Run `docker compose up --build`
  on the deployment host as the final container gate.

# SparkByte Docker

## Build

```bash
docker build -t sparkbyte .
```

## Run

```bash
docker run --rm -it -p 8081:8081 --env-file .env \
  -e SPARKBYTE_STATE_DIR=/app/runtime \
  -v sparkbyte-state:/app/runtime \
  sparkbyte
```

The container starts the SparkByte app on `http://127.0.0.1:8081/`.
Health status is available at `http://127.0.0.1:8081/health`.
Browser auto-launch is disabled inside Docker, but the app still boots a headless Playwright Chromium instance for `browse_url`.

If you want the container to reach an Ollama instance running on your host, add:

```bash
docker run --rm -it -p 8081:8081 --env-file .env \
  --add-host=host.docker.internal:host-gateway \
  -e SPARKBYTE_STATE_DIR=/app/runtime \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  -v sparkbyte-state:/app/runtime \
  sparkbyte
```

If port `8081` is already taken, remap the host side only, for example `-p 18081:8081`.

## Compose

```bash
docker compose up --build
```

## Notes

- The Docker image targets the root SparkByte app, not the nested `JulianMetaMorph` companion project.
- The Dockerfile now uses a multi-stage build so dependency install and Julia precompile stay cached while the final runtime image stays cleaner.
- `run_command` and the builder terminal now use PowerShell on Windows and a POSIX shell on Linux/macOS, so tool execution works inside the container.
- Builder file operations now normalize paths for Linux containers instead of assuming Windows backslashes everywhere.
- Ollama can be routed to the host via `OLLAMA_BASE_URL`; `compose.yaml` defaults that to `http://host.docker.internal:11434`.
- `compose.yaml` now loads `.env` into the container directly instead of relying only on shell interpolation.
- Runtime state now lives under `SPARKBYTE_STATE_DIR` when set. In Docker and Compose that defaults to `/app/runtime`, which is mounted as a named volume so SQLite, telemetry, health logs, and forged-tool state survive container restarts.
